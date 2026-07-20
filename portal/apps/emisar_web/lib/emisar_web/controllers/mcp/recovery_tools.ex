defmodule EmisarWeb.MCP.RecoveryTools do
  @moduledoc """
  Fixed operation recovery, state waiting, and run-history boundary.

  Operation lookup is credential-lineage scoped. Run reads retain the product's
  account/user scope, but expose only rows with the complete fixed MCP contract.
  """

  alias Emisar.{Crypto, MCPOperations, Runbooks, Runs}
  alias EmisarWeb.MCP.{Cancellation, CancellationRegistry, CatalogCursor, ResponseBudget}
  alias EmisarWeb.MCP.{RunbookTools, Service, WaitLimiter}

  @recheck_ms 2_000

  defmodule RecentInput do
    @moduledoc false
    defstruct ~w[operation_id runbook_execution_id step_id runner_ref action_id pack_ref scope limit cursor]a
  end

  @doc "Executes one of the three fixed recovery tools."
  def call(conn, "get_operation", args), do: get_operation(conn, args)
  def call(conn, "wait_for_run", args), do: wait_for_run(conn, args)
  def call(conn, "recent_runs", args), do: recent_runs(conn, args)

  defp get_operation(conn, args) do
    with {:ok, operation} <-
           MCPOperations.fetch_recovery(args["operation_id"], conn.assigns.current_subject),
         {:ok, projection} <- operation_projection(conn, operation) do
      {:ok, %{ok: true, operation: projection}}
    else
      {:error, :not_found} ->
        {:error,
         error(
           "operation_not_found",
           "No operation with that id belongs to this credential lineage."
         )}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot recover operations.")}

      {:error, :operation_resource_missing} ->
        {:error,
         error(
           "operation_incomplete",
           "The operation exists, but its durable resource is unavailable."
         )}
    end
  end

  defp operation_projection(_conn, %{tool: :run_action} = operation) do
    {:ok,
     %{
       operation_id: operation.operation_id,
       kind: "action",
       action_id: operation.action_id,
       pack_ref: operation.pack_ref,
       next: %{
         tool: "recent_runs",
         arguments: %{operation_id: operation.operation_id}
       }
     }}
  end

  defp operation_projection(_conn, %{tool: :execute_runbook} = operation) do
    {:ok,
     %{
       operation_id: operation.operation_id,
       kind: "runbook",
       runbook_execution_id: operation.resource_id,
       runbook_ref: operation.resource_ref,
       next: %{
         tool: "wait_for_run",
         arguments: %{runbook_execution_id: operation.resource_id, timeout: "0"}
       }
     }}
  end

  defp operation_projection(conn, %{tool: :create_runbook_draft} = operation) do
    case Runbooks.fetch_runbook_by_id(operation.resource_id, conn.assigns.current_subject) do
      {:ok, runbook} ->
        {:ok,
         %{
           operation_id: operation.operation_id,
           kind: "runbook_draft",
           draft_id: runbook.id,
           slug: runbook.slug,
           status: "draft",
           review_url:
             "#{EmisarWeb.Endpoint.url()}/app/#{conn.assigns.current_subject.account.slug}/runbooks/#{runbook.id}/edit"
         }}

      _ ->
        {:error, :operation_resource_missing}
    end
  end

  defp wait_for_run(conn, args) do
    case wait_for_target(conn, wait_target(args)) do
      {:ok, payload} ->
        {:ok, Map.put(payload, :ok, true)}

      {:error, :cancelled} ->
        :cancelled

      {:error, :not_found} ->
        {:error, error("run_not_found", "No visible run or execution has that id.")}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read that run.")}

      {:error, :wait_saturated} ->
        {:error,
         retryable_error(
           "wait_saturated",
           "This credential already has eight active waits. Retry after one finishes."
         )}
    end
  end

  # The published inputSchema's oneOf guarantees exactly one id, and its
  # wait_short pattern mirrors parse_wait's grammar exactly.
  defp wait_target(args) do
    {:ok, timeout_ms} = Service.parse_wait(args["timeout"] || "60s")

    case args do
      %{"run_id" => run_id} -> %{kind: :run, id: run_id, timeout_ms: timeout_ms}
      %{"runbook_execution_id" => id} -> %{kind: :execution, id: id, timeout_ms: timeout_ms}
    end
  end

  defp wait_for_target(conn, %{timeout_ms: 0} = target), do: do_wait_for_target(conn, target)

  defp wait_for_target(conn, target) do
    WaitLimiter.run(conn, fn -> do_wait_for_target(conn, target) end)
  end

  defp do_wait_for_target(conn, %{kind: :run} = target), do: wait_for_action_run(conn, target)

  defp do_wait_for_target(conn, %{kind: :execution} = target),
    do: wait_for_execution(conn, target)

  defp wait_for_action_run(conn, %{id: run_id, timeout_ms: timeout_ms}) do
    subject = conn.assigns.current_subject

    with {:ok, initial} <- Runs.fetch_mcp_run_by_id(run_id, subject) do
      if timeout_ms == 0 or Runs.ActionRun.terminal?(initial.status) do
        {:ok, %{run: Service.fixed_run_summary(initial, subject)}}
      else
        :ok = Runs.subscribe_run(subject.account.id, run_id)
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        try do
          await_action_run(
            subject,
            run_id,
            run_token(initial),
            deadline,
            Cancellation.topic(conn)
          )
        after
          :ok = Runs.unsubscribe_run(subject.account.id, run_id)
        end
      end
    end
  end

  defp await_action_run(subject, run_id, initial_token, deadline, cancellation_topic) do
    with :ok <- not_cancelled(cancellation_topic),
         {:ok, current} <- Runs.fetch_mcp_run_by_id(run_id, subject) do
      cond do
        Runs.ActionRun.terminal?(current.status) or run_token(current) != initial_token ->
          {:ok, %{run: Service.fixed_run_summary(current, subject)}}

        System.monotonic_time(:millisecond) >= deadline ->
          {:ok, %{run: Service.fixed_run_summary(current, subject)}}

        true ->
          wait_for_change(deadline, cancellation_topic)
          |> case do
            :cancelled ->
              {:error, :cancelled}

            _signal ->
              await_action_run(subject, run_id, initial_token, deadline, cancellation_topic)
          end
      end
    end
  end

  defp wait_for_execution(conn, %{id: execution_id, timeout_ms: timeout_ms}) do
    subject = conn.assigns.current_subject

    with {:ok, initial} <- execution_state(conn, execution_id) do
      if timeout_ms == 0 or terminal_execution?(initial.payload.status) do
        {:ok, %{execution: initial.payload}}
      else
        :ok = Runs.subscribe_account_runs(subject.account.id)
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        try do
          await_execution(
            conn,
            execution_id,
            initial.token,
            deadline,
            Cancellation.topic(conn)
          )
        after
          :ok = Runs.unsubscribe_account_runs(subject.account.id)
        end
      end
    end
  end

  defp await_execution(conn, execution_id, initial_token, deadline, cancellation_topic) do
    with :ok <- not_cancelled(cancellation_topic),
         {:ok, current} <- execution_state(conn, execution_id) do
      cond do
        terminal_execution?(current.payload.status) or current.token != initial_token ->
          {:ok, %{execution: current.payload}}

        System.monotonic_time(:millisecond) >= deadline ->
          {:ok, %{execution: current.payload}}

        true ->
          wait_for_change(deadline, cancellation_topic)
          |> case do
            :cancelled ->
              {:error, :cancelled}

            _signal ->
              await_execution(conn, execution_id, initial_token, deadline, cancellation_topic)
          end
      end
    end
  end

  defp execution_state(conn, execution_id) do
    subject = conn.assigns.current_subject

    with {:ok, execution} <- Runbooks.fetch_execution_by_id(execution_id, subject),
         {:ok, runbook} <- Runbooks.fetch_runbook_for_execution(execution, subject),
         {:ok, runs} <- Runs.list_runs_by_runbook_execution(execution.id, subject),
         {:ok, payload} <- RunbookTools.execution_payload_from_runs(execution, runbook, runs) do
      token =
        {execution.status, execution.updated_at,
         Enum.map(runs, &{&1.id, &1.status, &1.updated_at})}

      {:ok, %{payload: payload, token: token}}
    end
  end

  defp recent_runs(conn, args) do
    input = parse_recent_runs(args)
    scope = cursor_scope(conn)
    cursor_filters = recent_cursor_filters(input)

    with {:ok, page_cursor} <-
           CatalogCursor.decode(input.cursor, "recent_runs", scope, cursor_filters),
         {:ok, payload} <-
           recent_runs_page(conn, input, page_cursor, scope, cursor_filters, input.limit) do
      {:ok, payload}
    else
      {:error, :invalid_cursor} ->
        {:error,
         error("invalid_cursor", "The cursor is invalid, expired, or belongs to another query.")}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read run history.")}

      {:error, :response_too_large} ->
        {:error,
         error(
           "response_too_large",
           "One run summary exceeds the MCP response limit even without neighboring results."
         )}
    end
  end

  defp recent_runs_page(conn, input, page_cursor, scope, cursor_filters, limit) do
    page_opts = page_opts(limit, page_cursor)
    subject = conn.assigns.current_subject

    with {:ok, runs, metadata} <-
           Runs.list_recent_mcp_runs(Map.from_struct(input), subject, page_opts) do
      next_cursor =
        if metadata.next_page_cursor do
          CatalogCursor.encode(
            "recent_runs",
            scope,
            cursor_filters,
            metadata.next_page_cursor
          )
        end

      payload = %{
        ok: true,
        runs: Service.fixed_run_summaries(runs, subject),
        next_cursor: next_cursor
      }

      cond do
        ResponseBudget.fits_payload?(payload) ->
          {:ok, payload}

        limit > 1 ->
          recent_runs_page(conn, input, page_cursor, scope, cursor_filters, div(limit, 2))

        true ->
          {:error, :response_too_large}
      end
    end
  end

  # The controller already validated `args` against the published recent_runs
  # inputSchema, including its identity-combination rules; this builder only
  # applies the documented defaults.
  defp parse_recent_runs(args) do
    %__MODULE__.RecentInput{
      operation_id: args["operation_id"],
      runbook_execution_id: args["runbook_execution_id"],
      step_id: args["step_id"],
      runner_ref: args["runner_ref"],
      action_id: args["action_id"],
      pack_ref: args["pack_ref"],
      scope: if(args["scope"] == "account", do: :account, else: :own),
      limit: args["limit"] || 15,
      cursor: args["cursor"]
    }
  end

  defp recent_cursor_filters(input) do
    input
    |> Map.from_struct()
    |> Map.drop([:cursor])
    |> Map.update!(:scope, &Atom.to_string/1)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp cursor_scope(conn) do
    key = conn.assigns.api_key

    Crypto.hash_hex(conn.assigns.current_subject.account.id <> "\0" <> key.credential_lineage_id)
  end

  defp page_opts(limit, nil), do: [limit: limit]
  defp page_opts(limit, cursor), do: [limit: limit, cursor: cursor]

  defp wait_for_change(deadline, cancellation_topic) do
    timeout = min(max(deadline - System.monotonic_time(:millisecond), 0), @recheck_ms)

    receive do
      {:mcp_request_cancelled, ^cancellation_topic} when is_binary(cancellation_topic) ->
        :cancelled

      {:run_updated, _run} ->
        :changed

      {:run_event, _event} ->
        wait_for_change(deadline, cancellation_topic)
    after
      timeout -> :recheck
    end
  end

  defp not_cancelled(topic) when is_binary(topic) do
    if CancellationRegistry.cancelled?(topic), do: {:error, :cancelled}, else: :ok
  end

  defp not_cancelled(_topic), do: :ok

  defp run_token(run), do: {run.status, run.updated_at}
  defp terminal_execution?(status), do: status not in ~w(pending running pending_approval)

  defp error(code, message) do
    %{
      ok: false,
      error: %{code: code, message: message, retryable: false},
      dispatch_started: false
    }
  end

  defp retryable_error(code, message) do
    %{ok: false, error: %{code: code, message: message, retryable: true}, dispatch_started: false}
  end
end
