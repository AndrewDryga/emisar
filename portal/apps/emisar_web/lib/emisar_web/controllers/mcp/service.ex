defmodule EmisarWeb.MCP.Service do
  @moduledoc """
  Canonical MCP action dispatch, bounded result waiting, and run rendering.

  The JSON-RPC controller owns protocol envelopes. This module receives an
  authenticated connection, calls subject-gated domain contexts, and returns
  plain data for the fixed MCP tools.
  """

  alias Emisar.{Approvals, Runs}
  alias EmisarWeb.MCP.{Cancellation, WaitLimiter}

  @recheck_interval_ms 2_000
  @max_output_events 32
  @max_error_message_bytes 1_024

  @doc "Dispatches a preflighted fixed-catalog action and returns current run summaries."
  def dispatch_fixed_action(conn, targets, intent, wait_ms) do
    api_key = conn.assigns.api_key
    subject = conn.assigns.current_subject
    operation_attrs = intent.operation_attrs

    target_attrs =
      Enum.map(targets, fn target ->
        %{
          action_id: intent.action_id,
          runner_id: target.id,
          args: intent.args,
          args_raw: intent.args_raw,
          reason: intent.reason,
          source: "mcp",
          api_key_id: api_key.id,
          client_info: api_key.last_client_info || %{},
          attestation: intent.attestation,
          operation_id: operation_attrs.operation_id,
          pack_ref: intent.pack_ref,
          requested_by_membership_id: api_key.created_by_membership_id
        }
      end)

    with {:ok, runs} <- Runs.dispatch_mcp_fanout(operation_attrs, target_attrs, subject),
         true <- complete_target_set?(runs, targets),
         :ok <-
           maybe_poll_to_terminal(
             conn,
             subject,
             fixed_dispatch_results(runs, targets),
             wait_ms,
             Cancellation.topic(conn)
           ),
         {:ok, runs} <-
           Runs.list_runs_by_mcp_operation(hd(runs).mcp_operation_record_id, subject),
         true <- complete_target_set?(runs, targets) do
      {:ok, fixed_run_summaries(runs, subject)}
    else
      :cancelled -> {:error, :cancelled}
      false -> {:error, :operation_incomplete}
      other -> other
    end
  end

  @doc "Returns one committed fixed action operation without consulting current catalog state."
  def replay_fixed_action(conn, operation, wait_ms) do
    subject = conn.assigns.current_subject

    with {:ok, runs} <- Runs.list_runs_by_mcp_operation(operation.id, subject),
         false <- runs == [],
         :ok <-
           maybe_poll_to_terminal(
             conn,
             subject,
             fixed_replay_results(runs),
             wait_ms,
             Cancellation.topic(conn)
           ),
         {:ok, runs} <- Runs.list_runs_by_mcp_operation(operation.id, subject),
         false <- runs == [] do
      {:ok, fixed_run_summaries(runs, subject)}
    else
      :cancelled -> {:error, :cancelled}
      true -> {:error, :operation_incomplete}
      other -> other
    end
  end

  defp fixed_replay_results(runs) do
    Enum.map(runs, fn run ->
      {run.runner_ref, fixed_dispatch_result(run), nil}
    end)
  end

  defp fixed_dispatch_results(runs, targets) do
    targets_by_id = Map.new(targets, &{&1.id, &1})

    Enum.map(runs, fn run ->
      target = Map.fetch!(targets_by_id, run.runner_id)
      {target.name, fixed_dispatch_result(run), target}
    end)
  end

  defp fixed_dispatch_result(%{status: :denied, policy_reason: reason}),
    do: {:error, :denied_by_policy, reason || "policy denied this call"}

  defp fixed_dispatch_result(%{status: :pending_approval} = run),
    do: {:ok, :pending_approval, run}

  defp fixed_dispatch_result(run), do: {:ok, :running, run}

  defp complete_target_set?(runs, targets) do
    MapSet.new(runs, & &1.runner_id) == MapSet.new(targets, & &1.id)
  end

  @doc "Renders fixed-contract run summaries within one 64 KiB output-preview budget."
  def fixed_run_summaries(runs, subject) when is_list(runs) do
    stream_cap = min(16_384, div(65_536, max(2 * length(runs), 1)))
    structured_output_cap = min(8_192, div(65_536, max(length(runs), 1)))

    Enum.map(runs, &fixed_run_summary(&1, subject, stream_cap, structured_output_cap))
  end

  @doc "Renders one fixed-contract run summary. A stream that produced no bytes is omitted."
  def fixed_run_summary(run, subject, stream_cap \\ 16_384, structured_output_cap \\ 8_192) do
    output_preview = run_output_preview(run, subject, stream_cap)
    structured_output = structured_output_summary(run.structured_output, structured_output_cap)
    {approval, approval_wait_until} = fixed_approval(run, subject)

    %{
      run_id: run.id,
      operation_id: run.operation_id,
      action_id: run.action_id,
      pack_ref: run.pack_ref,
      runner_ref: run.runner_ref,
      runbook_execution_id: run.runbook_execution_id,
      step_id: run.runbook_step_id,
      status: to_string(run.status),
      created_at: run.inserted_at,
      finished_at: run.finished_at,
      exit_code: run.exit_code,
      duration_ms: run.duration_ms,
      error_message: fixed_error_message(run),
      output_complete: if(terminal_output_complete(run) == false, do: false),
      local_audit_failed: if(run.local_audit_failed, do: true),
      approval: approval,
      wait_until: approval_wait_until || fixed_wait_until(run),
      next: fixed_run_next(run, structured_output),
      run_url: "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/runs/#{run.id}"
    }
    |> Map.merge(structured_output)
    |> Map.merge(stream_summary(run, output_preview, :stdout))
    |> Map.merge(stream_summary(run, output_preview, :stderr))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp structured_output_summary(nil, _cap), do: %{}

  defp structured_output_summary(output, cap) do
    encoded_size = output |> Jason.encode_to_iodata!() |> IO.iodata_length()

    if encoded_size <= cap,
      do: %{structured_output: output},
      else: %{structured_output_omitted: true}
  end

  # A stream that produced no bytes carries no information: its preview, byte
  # count, and truncation flag are omitted so terse results stay terse for LLM
  # clients (`output_complete` mirrors this by appearing only when false).
  defp stream_summary(run, %{stdout: preview} = output_preview, :stdout) do
    if (run.emitted_stdout_bytes || 0) == 0 and preview == "" do
      %{}
    else
      %{
        stdout: preview,
        emitted_stdout_bytes: run.emitted_stdout_bytes,
        truncated_stdout:
          output_truncated?(
            preview,
            run.emitted_stdout_bytes,
            run.stdout_truncated,
            output_preview.stdout_truncated,
            output_preview.output_events_truncated
          )
      }
    end
  end

  defp stream_summary(run, %{stderr: preview} = output_preview, :stderr) do
    if (run.emitted_stderr_bytes || 0) == 0 and preview == "" do
      %{}
    else
      %{
        stderr: preview,
        emitted_stderr_bytes: run.emitted_stderr_bytes,
        truncated_stderr:
          output_truncated?(
            preview,
            run.emitted_stderr_bytes,
            run.stderr_truncated,
            output_preview.stderr_truncated,
            output_preview.output_events_truncated
          )
      }
    end
  end

  defp output_truncated?(
         preview,
         total_bytes,
         runner_truncated?,
         locally_truncated?,
         events_truncated?
       ) do
    runner_truncated? or locally_truncated? or events_truncated? or
      (is_integer(total_bytes) and total_bytes > byte_size(preview))
  end

  defp terminal_output_complete(%{status: status, output_complete: complete?}) do
    if Runs.ActionRun.terminal?(status), do: complete?, else: nil
  end

  defp fixed_approval(%{status: :pending_approval} = run, subject) do
    case Approvals.fetch_request_for_visible_run(run, subject) do
      {:ok, request} ->
        approval = %{
          request_id: request.id,
          url: "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/approvals/#{request.id}",
          expires_at: request.expires_at
        }

        {approval, request.expires_at}

      _ ->
        {nil, nil}
    end
  end

  defp fixed_approval(_run, _subject), do: {nil, nil}

  # Policy and approval causes are control-plane facts. Do not substitute the
  # operator's freeform run reason here: it is untrusted context and may carry
  # action-specific secrets.
  defp fixed_error_message(%{status: :denied} = run),
    do: policy_denial_preview(run.policy_reason)

  defp fixed_error_message(%{
         status: :cancelled,
         reason_text: <<"approval denied", _::binary>> = reason
       }),
       do: error_message_preview(reason)

  defp fixed_error_message(%{error_message: message}), do: error_message_preview(message)

  defp policy_denial_preview(reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      "Denied by policy: no specific policy reason was recorded."
    else
      error_message_preview("Denied by policy: " <> reason)
    end
  end

  defp policy_denial_preview(_reason),
    do: "Denied by policy: no specific policy reason was recorded."

  # DispatchTimeout gives an acknowledged-or-terminal decision ten minutes
  # after queueing. Expose that durable deadline rather than inventing a wait
  # horizon from this particular HTTP request.
  defp fixed_wait_until(%{status: :sent, queued_at: %DateTime{} = queued_at}),
    do: DateTime.add(queued_at, 600, :second)

  defp fixed_wait_until(_run), do: nil

  defp fixed_run_next(%{id: run_id}, %{structured_output_omitted: true}),
    do: %{tool: "wait_for_run", arguments: %{run_id: run_id, timeout: "0"}}

  defp fixed_run_next(%{status: status, id: run_id}, _structured_output) do
    if Runs.ActionRun.terminal?(status),
      do: nil,
      else: %{tool: "wait_for_run", arguments: %{run_id: run_id, timeout: "60s"}}
  end

  # -- Wait parsing ---------------------------------------------------

  @doc ~s(Parses the public wait_short grammar: "0", 1..60s, or 1..60000ms.)
  @spec parse_wait(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_wait("0"), do: {:ok, 0}

  def parse_wait(value) when is_binary(value) do
    case Regex.run(~r/\A([1-9]|[1-5][0-9]|60)s\z/, value) do
      [_, seconds] ->
        {:ok, String.to_integer(seconds) * 1_000}

      _ ->
        case Regex.run(~r/\A([1-9][0-9]{0,3}|[1-5][0-9]{4}|60000)ms\z/, value) do
          [_, milliseconds] -> {:ok, String.to_integer(milliseconds)}
          _ -> :error
        end
    end
  end

  def parse_wait(_value), do: :error

  # -- Per-runner long-poll + result rendering ------------------------

  defp maybe_poll_to_terminal(_conn, _subject, _results, 0, _cancellation_topic), do: :ok

  defp maybe_poll_to_terminal(conn, subject, results, ms, cancellation_topic) do
    polling_ids =
      for {_name, {:ok, :running, %{id: id}}, _runner} <- results, do: id

    if polling_ids == [] do
      :ok
    else
      deadline = System.monotonic_time(:millisecond) + ms

      case WaitLimiter.run(conn, fn ->
             poll_all_to_terminal(subject, polling_ids, deadline, cancellation_topic)
           end) do
        # The mutation is already durable. Capacity exhaustion changes only
        # response latency; the caller receives the current accepted state.
        {:error, :wait_saturated} -> :ok
        result -> result
      end
    end
  end

  # Block until every run in `ids` is terminal or the deadline passes. The
  # runner socket broadcasts `{:run_updated, _}` on each run's topic at every
  # state transition (Runs broadcasts on the run topic), so we subscribe and wake
  # on those instead of busy-polling; the recheck timer is the safety net.
  defp poll_all_to_terminal(subject, ids, deadline, cancellation_topic) do
    Enum.each(ids, &Runs.subscribe_run(subject.account.id, &1))
    schedule_recheck(deadline)

    try do
      await_all_terminal(subject, ids, deadline, cancellation_topic)
    after
      Enum.each(ids, &Runs.unsubscribe_run(subject.account.id, &1))
    end
  end

  defp await_all_terminal(subject, ids, deadline, cancellation_topic) do
    remaining = Enum.reject(ids, &run_terminal?(&1, subject))

    if remaining == [] do
      :ok
    else
      case wait_for_signal(deadline, cancellation_topic) do
        :recheck ->
          schedule_recheck(deadline)
          await_all_terminal(subject, remaining, deadline, cancellation_topic)

        {:run_updated, _run} ->
          await_all_terminal(subject, remaining, deadline, cancellation_topic)

        :cancelled ->
          :cancelled

        :timeout ->
          :ok
      end
    end
  end

  defp run_terminal?(run_id, subject) do
    case Runs.fetch_run_by_id(run_id, subject) do
      {:ok, %{status: status}} -> Runs.ActionRun.terminal?(status)
      _ -> false
    end
  end

  # Block until a relevant PubSub message arrives, the recheck timer fires, or
  # the deadline's remaining budget elapses — whichever comes first. Returns the
  # signal so the caller decides whether to re-check the run(s) or give up.
  # `{:run_event, _}` progress chunks are drained in place (they don't change
  # status, so re-querying on each would re-amplify DB load on a chatty run)
  # without resetting the deadline; a state change still arrives as
  # `{:run_updated, _}`, and the recheck timer backstops anything missed.
  defp wait_for_signal(deadline, cancellation_topic) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      :recheck ->
        :recheck

      {:run_updated, run} ->
        {:run_updated, run}

      {:run_event, _event} ->
        wait_for_signal(deadline, cancellation_topic)

      {:mcp_request_cancelled, ^cancellation_topic} when is_binary(cancellation_topic) ->
        :cancelled
    after
      timeout -> :timeout
    end
  end

  defp schedule_recheck(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      Process.send_after(self(), :recheck, min(@recheck_interval_ms, remaining))
    end
  end

  defp run_output_preview(run, subject, stream_cap) do
    {:ok, events} = Runs.list_recent_events_for_run(run.id, @max_output_events + 1, subject)
    {events, output_events_truncated?} = output_tail(events)

    {{stdout, stdout_truncated?}, {stderr, stderr_truncated?}} =
      collect_streams(events, stream_cap)

    %{
      stdout: stdout,
      stderr: stderr,
      stdout_truncated: run.stdout_truncated or stdout_truncated?,
      stderr_truncated: run.stderr_truncated or stderr_truncated?,
      output_events_truncated: output_events_truncated?
    }
  end

  defp output_tail(events) when length(events) > @max_output_events,
    do: {tl(events), true}

  defp output_tail(events), do: {events, false}

  defp collect_streams(events, stream_cap) do
    Enum.reduce(events, {{"", false}, {"", false}}, fn event, {out, err} ->
      chunk = get_chunk(event)
      stream = event.stream || (event.payload && event.payload["stream"])

      case stream do
        "stderr" -> {out, append_tail(err, chunk, stream_cap)}
        _ -> {append_tail(out, chunk, stream_cap), err}
      end
    end)
  end

  defp append_tail({output, truncated?}, chunk, cap) do
    combined = output <> chunk
    {truncate(combined, cap), truncated? or byte_size(combined) > cap}
  end

  defp get_chunk(%{payload: %{"chunk" => c}}) when is_binary(c), do: c
  defp get_chunk(_), do: ""

  defp truncate(s, n) when byte_size(s) <= n, do: s

  defp truncate(s, n) do
    s
    |> binary_part(byte_size(s) - n, n)
    |> drop_incomplete_utf8_prefix(0)
  end

  defp drop_incomplete_utf8_prefix(value, dropped) when dropped < 4 do
    if String.valid?(value),
      do: value,
      else: drop_incomplete_utf8_prefix(tl_binary(value), dropped + 1)
  end

  defp drop_incomplete_utf8_prefix(_value, _dropped), do: ""

  defp error_message_preview(nil), do: nil

  defp error_message_preview(message) when byte_size(message) <= @max_error_message_bytes,
    do: message

  defp error_message_preview(message) do
    suffix = "..."
    prefix_bytes = @max_error_message_bytes - byte_size(suffix)

    prefix =
      message
      |> binary_part(0, prefix_bytes)
      |> drop_incomplete_utf8_suffix(0)

    prefix <> suffix
  end

  defp drop_incomplete_utf8_suffix(value, dropped) when dropped < 4 do
    if String.valid?(value),
      do: value,
      else: drop_incomplete_utf8_suffix(init_binary(value), dropped + 1)
  end

  defp drop_incomplete_utf8_suffix(_value, _dropped), do: ""
  defp tl_binary(<<_byte, rest::binary>>), do: rest
  defp tl_binary(<<>>), do: <<>>
  defp init_binary(value), do: binary_part(value, 0, byte_size(value) - 1)
end
