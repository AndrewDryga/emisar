defmodule EmisarWeb.MCP.RecoveryTools do
  @moduledoc """
  Fixed operation recovery, state waiting, and run-history boundary.

  Operation lookup is credential-lineage scoped. Run reads retain the product's
  account/user scope, but expose only rows with the complete fixed MCP contract.
  """

  alias Emisar.{MCPOperations, Runbooks, Runs}
  alias EmisarWeb.MCP.{Cancellation, CancellationRegistry, CatalogCursor, OutputCursor}
  alias EmisarWeb.MCP.{ResponseBudget, RunbookTools, Service, WaitLimiter}

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

  defp operation_projection(conn, %{tool: :execute_runbook} = operation) do
    case Runbooks.fetch_execution_recovery_identity(
           operation.resource_id,
           conn.assigns.current_subject
         ) do
      {:ok, %{kind: :draft_test} = execution} ->
        {:ok, runbook_operation_projection(operation, execution.definition_sha256)}

      {:ok, _execution} ->
        {:ok, runbook_operation_projection(operation)}

      {:error, _reason} ->
        {:error, :operation_resource_missing}
    end
  end

  defp operation_projection(conn, %{tool: tool} = operation)
       when tool in [:create_runbook_draft, :update_runbook_draft] do
    case Runbooks.fetch_runbook_by_id(operation.resource_id, conn.assigns.current_subject) do
      {:ok, runbook} ->
        {:ok,
         %{
           operation_id: operation.operation_id,
           kind: "runbook_draft",
           draft_id: runbook.id,
           runbook_ref: "#{runbook.slug}@#{runbook.version}",
           slug: runbook.slug,
           status: "draft",
           definition_sha256: Runbooks.definition_digest(runbook.definition),
           review_url:
             "#{EmisarWeb.Endpoint.url()}/app/#{conn.assigns.current_subject.account.slug}/runbooks/#{runbook.id}/edit"
         }}

      _ ->
        {:error, :operation_resource_missing}
    end
  end

  defp runbook_operation_projection(operation) do
    %{
      operation_id: operation.operation_id,
      kind: "runbook",
      runbook_execution_id: operation.resource_id,
      runbook_ref: operation.resource_ref,
      next: %{
        tool: "wait_for_run",
        arguments: %{runbook_execution_id: operation.resource_id, timeout: "0"}
      }
    }
  end

  defp runbook_operation_projection(operation, definition_sha256) do
    operation
    |> runbook_operation_projection()
    |> Map.put(:kind, "runbook_draft_test")
    |> Map.put(:definition_sha256, definition_sha256)
  end

  defp wait_for_run(conn, args) do
    case wait_for_target(conn, wait_target(args)) do
      {:ok, payload} ->
        {:ok, Map.put(payload, :ok, true)}

      {:error, :cancelled} ->
        :cancelled

      {:error, :invalid_cursor} ->
        {:error, error("invalid_cursor", Service.invalid_cursor_message(:tail, "wait_for_run"))}

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
      %{"run_id" => run_id} ->
        %{kind: :run, id: run_id, timeout_ms: timeout_ms, cursor: args["cursor"]}

      %{"runbook_execution_id" => id} ->
        %{kind: :execution, id: id, timeout_ms: timeout_ms}
    end
  end

  defp wait_for_target(conn, %{timeout_ms: 0} = target), do: do_wait_for_target(conn, target)

  defp wait_for_target(conn, target) do
    WaitLimiter.run(conn, fn -> do_wait_for_target(conn, target) end)
  end

  defp do_wait_for_target(conn, %{kind: :run} = target), do: wait_for_action_run(conn, target)

  defp do_wait_for_target(conn, %{kind: :execution} = target),
    do: wait_for_execution(conn, target)

  defp wait_for_action_run(conn, %{id: run_id, timeout_ms: timeout_ms} = target) do
    subject = conn.assigns.current_subject
    scope = Service.cursor_scope(conn)

    with {:ok, position} <- resolve_output_cursor(target, scope, run_id),
         {:ok, initial} <- Runs.fetch_mcp_run_by_id(run_id, subject) do
      render = &render_action_run(&1, subject, position, scope)
      rendered = render.(initial)

      cond do
        timeout_ms == 0 or Runs.terminal_status?(initial.status) ->
          {:ok, %{run: rendered}}

        # Output is already waiting past the cursor. Return it now: it is already
        # counted in this request's token, so no later event would wake the wait
        # and the caller would block the whole window for output we already have.
        tail_advanced?(rendered) ->
          {:ok, %{run: rendered}}

        true ->
          :ok = Runs.subscribe_run(subject.account.id, run_id)
          deadline = System.monotonic_time(:millisecond) + timeout_ms

          try do
            await_action_run(
              subject,
              run_id,
              run_token(initial),
              wake_seq(position),
              deadline,
              Cancellation.topic(conn),
              render
            )
          after
            :ok = Runs.unsubscribe_run(subject.account.id, run_id)
          end
      end
    end
  end

  # A cursor-mode render that already produced output — there is nothing to wait
  # for. A snapshot render has no `:output` key and always falls through to wait.
  defp tail_advanced?(%{output: [_ | _]}), do: true
  defp tail_advanced?(_rendered), do: false

  defp resolve_output_cursor(%{cursor: nil}, _scope, _run_id), do: {:ok, nil}

  defp resolve_output_cursor(%{cursor: cursor}, scope, run_id),
    do: OutputCursor.decode(cursor, scope, run_id)

  defp render_action_run(run, subject, nil, scope),
    do: Service.fixed_run_summary(run, subject, tail_scope: scope)

  defp render_action_run(run, subject, {_, _, _} = position, scope),
    do: Service.fixed_run_tail(run, subject, position, scope)

  # The wake watches for the NEXT event to deliver; a fragmented mid-event
  # position drains immediately (timeout "0"), so only its seq matters here.
  defp wake_seq(nil), do: nil
  defp wake_seq({seq, _offset, _remaining}), do: seq

  defp await_action_run(
         subject,
         run_id,
         initial_token,
         wake_seq,
         deadline,
         cancellation_topic,
         render
       ) do
    with :ok <- not_cancelled(cancellation_topic),
         {:ok, current} <- Runs.fetch_mcp_run_by_id(run_id, subject) do
      cond do
        Runs.terminal_status?(current.status) or run_token(current) != initial_token ->
          {:ok, %{run: render.(current)}}

        System.monotonic_time(:millisecond) >= deadline ->
          {:ok, %{run: render.(current)}}

        true ->
          case wait_for_change(deadline, cancellation_topic, wake_seq) do
            :cancelled ->
              {:error, :cancelled}

            _signal ->
              await_action_run(
                subject,
                run_id,
                initial_token,
                wake_seq,
                deadline,
                cancellation_topic,
                render
              )
          end
      end
    end
  end

  defp wait_for_execution(conn, %{id: execution_id, timeout_ms: timeout_ms}) do
    subject = conn.assigns.current_subject

    with {:ok, initial} <- execution_state(conn, execution_id) do
      if timeout_ms == 0 or not initial.waitable? do
        {:ok, %{execution: initial.payload}}
      else
        :ok = Runbooks.subscribe_execution(subject.account.id, execution_id)
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
          :ok = Runbooks.unsubscribe_execution(subject.account.id, execution_id)
        end
      end
    end
  end

  defp await_execution(conn, execution_id, initial_token, deadline, cancellation_topic) do
    with :ok <- not_cancelled(cancellation_topic),
         {:ok, current} <- execution_state(conn, execution_id) do
      cond do
        not current.waitable? or current.token != initial_token ->
          {:ok, %{execution: current.payload}}

        System.monotonic_time(:millisecond) >= deadline ->
          {:ok, %{execution: current.payload}}

        true ->
          case wait_for_change(deadline, cancellation_topic, nil) do
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

    with {:ok, result} <- Runbooks.fetch_execution_result(execution_id, subject),
         projection = Runbooks.execution_projection(result),
         {:ok, payload} <- RunbookTools.project_execution(result, projection, subject) do
      execution = result.execution

      token =
        {execution.status, execution.updated_at,
         Enum.map(execution.stages, &{&1.id, &1.status, &1.updated_at}),
         Enum.map(execution.items, &{&1.id, &1.status, &1.updated_at}),
         Enum.map(result.latest_attempts, &{&1.id, &1.status, &1.updated_at})}

      {:ok, %{payload: payload, waitable?: projection.execution.waitable?, token: token}}
    end
  end

  defp recent_runs(conn, args) do
    input = parse_recent_runs(args)
    scope = Service.cursor_scope(conn)
    cursor_filters = recent_cursor_filters(input)

    with {:ok, page_cursor} <-
           CatalogCursor.decode(input.cursor, "recent_runs", scope, cursor_filters),
         {:ok, payload} <-
           recent_runs_page(conn, input, page_cursor, scope, cursor_filters, input.limit) do
      {:ok, payload}
    else
      {:error, :invalid_cursor} ->
        {:error, error("invalid_cursor", Service.invalid_cursor_message(:page, "recent_runs"))}

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
        runs: Service.fixed_run_summaries(runs, subject, tail_scope: scope),
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

  defp page_opts(limit, nil), do: [limit: limit]
  defp page_opts(limit, cursor), do: [limit: limit, cursor: cursor]

  defp wait_for_change(deadline, cancellation_topic, wake_seq) do
    timeout = min(max(deadline - System.monotonic_time(:millisecond), 0), @recheck_ms)

    receive do
      {:mcp_request_cancelled, ^cancellation_topic} when is_binary(cancellation_topic) ->
        :cancelled

      {:run_updated, _run} ->
        :changed

      {:runbook_execution_updated, _execution_id} ->
        :changed

      # In tail mode, arrival of the next event to deliver is the change the
      # caller is waiting for — wake now instead of at the recheck. Snapshot mode
      # (nil wake_seq) still only wakes on a status transition.
      {:run_event, %{kind: :progress, seq: seq}} when is_integer(wake_seq) and seq >= wake_seq ->
        :changed

      {:run_event, _event} ->
        wait_for_change(deadline, cancellation_topic, wake_seq)
    after
      timeout -> :recheck
    end
  end

  defp not_cancelled(topic) when is_binary(topic) do
    if CancellationRegistry.cancelled?(topic), do: {:error, :cancelled}, else: :ok
  end

  defp not_cancelled(_topic), do: :ok

  # The wait wakes on a status transition or new output. `progress_event_count`
  # increments on every accepted chunk (`ActionRun.Changeset.record_progress/2`),
  # so it provably changes when output arrives — unlike `updated_at`, which is an
  # incidental side effect. The `wait_for_run tail wakes on a new output chunk`
  # test guards this: a chunk must move the token.
  defp run_token(run), do: {run.status, run.progress_event_count}

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
