defmodule EmisarWeb.MCP.RecoveryTools do
  @moduledoc """
  Fixed operation recovery, state waiting, and run-history boundary.

  Operation lookup is credential-lineage scoped. Run reads retain the product's
  account/user scope, but expose only rows with the complete fixed MCP contract.
  """

  alias Emisar.{Catalog, Crypto, MCPOperations, Runbooks, Runs}
  alias EmisarWeb.MCP.{Cancellation, CancellationRegistry, CatalogCursor, ResponseBudget}
  alias EmisarWeb.MCP.{RunbookTools, Service}

  @operation_id ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/
  @action_id ~r/\A[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+\z/
  @runner_ref ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}~[0-9a-f]{32}\z/
  @step_id ~r/\A[a-z][a-z0-9_-]{0,79}\z/
  @max_wait_ms 300_000
  @recheck_ms 2_000

  @doc "Executes one of the three fixed recovery tools."
  def call(conn, "get_operation", args), do: get_operation(conn, args)
  def call(conn, "wait_for_run", args), do: wait_for_run(conn, args)
  def call(conn, "recent_runs", args), do: recent_runs(conn, args)

  defp get_operation(conn, args) do
    with :ok <- exact_fields(args, ~w(operation_id), ~w(operation_id)),
         operation_id when is_binary(operation_id) <- args["operation_id"],
         true <- Regex.match?(@operation_id, operation_id),
         {:ok, operation} <-
           MCPOperations.fetch_recovery(operation_id, conn.assigns.current_subject),
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

      _ ->
        {:error, error("invalid_args", "get_operation requires one exact operation_id.")}
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
    with {:ok, target} <- validate_wait(args),
         {:ok, payload} <- wait_for_target(conn, target) do
      {:ok, Map.put(payload, :ok, true)}
    else
      {:error, :cancelled} ->
        :cancelled

      {:error, :not_found} ->
        {:error, error("run_not_found", "No visible run or execution has that id.")}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read that run.")}

      {:error, :invalid_wait} ->
        {:error,
         error("invalid_args", "wait_for_run requires one id and a timeout no longer than 5m.")}
    end
  end

  defp validate_wait(args) do
    with :ok <-
           exact_fields(
             args,
             [],
             ~w(run_id runbook_execution_id timeout)
           ),
         run_id <- args["run_id"],
         execution_id <- args["runbook_execution_id"],
         true <- exactly_one?(run_id, execution_id),
         true <- valid_uuid_or_nil?(run_id) and valid_uuid_or_nil?(execution_id),
         {:ok, timeout_ms} <- parse_wait(args["timeout"] || "5m") do
      target =
        if run_id,
          do: %{kind: :run, id: run_id, timeout_ms: timeout_ms},
          else: %{kind: :execution, id: execution_id, timeout_ms: timeout_ms}

      {:ok, target}
    else
      _ -> {:error, :invalid_wait}
    end
  end

  defp wait_for_target(conn, %{kind: :run} = target), do: wait_for_action_run(conn, target)
  defp wait_for_target(conn, %{kind: :execution} = target), do: wait_for_execution(conn, target)

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
    with {:ok, input} <- validate_recent_runs(args),
         scope <- cursor_scope(conn),
         cursor_filters <- recent_cursor_filters(input),
         {:ok, page_cursor} <-
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

      {:error, :invalid_recent_runs} ->
        {:error, error("invalid_args", "recent_runs arguments do not match the fixed contract.")}

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

  defp validate_recent_runs(args) do
    allowed =
      ~w(operation_id runbook_execution_id step_id runner_ref action_id pack_ref scope limit cursor)

    with :ok <- exact_fields(args, [], allowed),
         :ok <- optional_match(args["operation_id"], @operation_id),
         :ok <- optional_uuid(args["runbook_execution_id"]),
         :ok <- optional_match(args["step_id"], @step_id),
         :ok <- optional_match(args["runner_ref"], @runner_ref),
         :ok <- optional_match(args["action_id"], @action_id),
         :ok <- optional_pack_ref(args["pack_ref"]),
         scope when scope in ["own", "account"] <- args["scope"] || "own",
         limit when is_integer(limit) and limit in 1..100 <- args["limit"] || 15,
         cursor when is_nil(cursor) or is_binary(cursor) <- args["cursor"],
         :ok <- valid_recent_combination(args) do
      {:ok,
       struct!(__MODULE__.RecentInput, %{
         operation_id: args["operation_id"],
         runbook_execution_id: args["runbook_execution_id"],
         step_id: args["step_id"],
         runner_ref: args["runner_ref"],
         action_id: args["action_id"],
         pack_ref: args["pack_ref"],
         scope: if(scope == "own", do: :own, else: :account),
         limit: limit,
         cursor: cursor
       })}
    else
      _ -> {:error, :invalid_recent_runs}
    end
  end

  defmodule RecentInput do
    @moduledoc false
    defstruct ~w[operation_id runbook_execution_id step_id runner_ref action_id pack_ref scope limit cursor]a
  end

  defp valid_recent_combination(args) do
    other_identity? =
      Enum.any?(~w(runbook_execution_id step_id runner_ref action_id pack_ref), &args[&1])

    cond do
      args["operation_id"] && other_identity? -> {:error, :invalid_combination}
      args["step_id"] && is_nil(args["runbook_execution_id"]) -> {:error, :invalid_combination}
      true -> :ok
    end
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

  defp exactly_one?(left, right),
    do: (is_binary(left) and is_nil(right)) or (is_nil(left) and is_binary(right))

  defp valid_uuid_or_nil?(nil), do: true
  defp valid_uuid_or_nil?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))

  defp parse_wait(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{1,8})(ms|s|m)?\z/, value) do
      [_, amount, unit] -> bounded_wait(String.to_integer(amount), unit)
      [_, amount] -> bounded_wait(String.to_integer(amount), "s")
      _ -> {:error, :invalid_wait}
    end
  end

  defp parse_wait(_value), do: {:error, :invalid_wait}

  defp bounded_wait(amount, unit) do
    multiplier = %{"ms" => 1, "s" => 1_000, "m" => 60_000}[unit]
    value = amount * multiplier
    if value <= @max_wait_ms, do: {:ok, value}, else: {:error, :invalid_wait}
  end

  defp optional_match(nil, _regex), do: :ok

  defp optional_match(value, regex) do
    if is_binary(value) and Regex.match?(regex, value),
      do: :ok,
      else: {:error, :invalid_value}
  end

  defp optional_uuid(nil), do: :ok

  defp optional_uuid(value) do
    if is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value)),
      do: :ok,
      else: {:error, :invalid_value}
  end

  defp optional_pack_ref(nil), do: :ok

  defp optional_pack_ref(value) do
    case Catalog.MCPProjection.parse_pack_ref(value) do
      {:ok, _parts} -> :ok
      _ -> {:error, :invalid_value}
    end
  end

  defp exact_fields(map, required, allowed) when is_map(map) do
    if Enum.all?(required, &Map.has_key?(map, &1)) and Enum.all?(Map.keys(map), &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp exact_fields(_map, _required, _allowed), do: {:error, :invalid_fields}

  defp error(code, message) do
    %{
      ok: false,
      error: %{code: code, message: message, retryable: false},
      dispatch_started: false
    }
  end
end
