defmodule EmisarWeb.MCP.Service do
  @moduledoc """
  Canonical MCP action dispatch, bounded result waiting, and run rendering.

  The JSON-RPC controller owns protocol envelopes. This module receives an
  authenticated connection, calls subject-gated domain contexts, and returns
  plain data for the fixed MCP tools.
  """

  alias Emisar.{Approvals, Crypto, Runs}
  alias EmisarWeb.MCP.{Cancellation, OutputCursor, ResponseBudget, WaitLimiter}

  @recheck_interval_ms 2_000
  @max_output_events 32
  @max_error_message_bytes 1_024
  # Raw-byte budget for ONE tail read. Bounds memory and sizes a frame; the
  # frame's real ceiling is enforced by `fits_frame?/1`, not by this number.
  @max_tail_read_bytes 200 * 1_024

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
          evidence: intent.evidence,
          expected: intent.expected,
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
      {:ok, fixed_run_summaries(runs, subject, tail_scope: cursor_scope(conn))}
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
      {:ok, fixed_run_summaries(runs, subject, tail_scope: cursor_scope(conn))}
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

  @doc "The credential-lineage scope binding a run's output cursor to one account + key."
  def cursor_scope(conn) do
    key = conn.assigns.api_key
    Crypto.hash_hex(conn.assigns.current_subject.account.id <> "\0" <> key.credential_lineage_id)
  end

  @doc "Renders fixed-contract run summaries within one 64 KiB output-preview budget."
  def fixed_run_summaries(runs, subject, opts \\ []) when is_list(runs) do
    summary_opts = [
      stream_cap: min(16_384, div(65_536, max(2 * length(runs), 1))),
      structured_output_cap: min(8_192, div(65_536, max(length(runs), 1))),
      tail_scope: Keyword.get(opts, :tail_scope)
    ]

    Enum.map(runs, &fixed_run_summary(&1, subject, summary_opts))
  end

  @doc """
  Renders one fixed-contract run summary (the tail-snapshot shape). A stream that
  produced no bytes is omitted. Pass `:tail_scope` to seed a live run's `next`
  with a start cursor so the caller can begin streaming its output forward.
  """
  def fixed_run_summary(run, subject, opts \\ []) do
    stream_cap = Keyword.get(opts, :stream_cap, 16_384)
    structured_output_cap = Keyword.get(opts, :structured_output_cap, 8_192)
    tail_scope = Keyword.get(opts, :tail_scope)
    output_preview = run_output_preview(run, subject, stream_cap)
    structured_output = structured_output_summary(run.structured_output, structured_output_cap)

    {next, drain_vanished?} =
      fixed_run_next(run, subject, structured_output, tail_scope, output_preview)

    run
    |> base_run_fields(subject)
    |> Map.put(:next, next)
    |> Map.merge(structured_output)
    |> Map.merge(stream_summary(run, output_preview, :stdout))
    |> Map.merge(stream_summary(run, output_preview, :stderr))
    |> flag_output_gap(drain_vanished?)
    |> drop_nil_values()
  end

  @doc """
  Renders a run summary in output-tail mode: a forward `output` delta of the
  progress chunks after `after_seq`, plus a `next` carrying the advanced cursor
  while the run is live or output remains undrained. Replaces the stdout/stderr
  tail preview; `scope` binds the emitted cursor to this run and credential.
  """
  def fixed_run_tail(run, subject, {from_seq, offset, _remaining} = position, scope)
      when is_integer(from_seq) and is_integer(offset) and is_binary(scope) do
    {:ok, events, read_more?} =
      Runs.list_events_for_run_since(run.id, from_seq, @max_tail_read_bytes, subject)

    {segments, gap?} = deliverable_segments(events, position)
    structured_output = structured_output_summary(run.structured_output, 8_192)

    context = %{
      run: run,
      subject: subject,
      scope: scope,
      position: position,
      segments: segments,
      structured_output: structured_output,
      read_more?: read_more?,
      gap?: gap?
    }

    build = &tail_summary(context, &1)
    total = Enum.reduce(segments, 0, &(byte_size(&1.text) + &2))
    summary = build.(total)

    # Measure the REAL assembled frame instead of estimating it. The transport
    # mirrors the payload into BOTH structuredContent and an escaped text block,
    # so escape-heavy output (a quote costs 2 bytes in one and 4 in the other)
    # runs far past its own encoded size. Only shrink when it actually overruns.
    if fits_frame?(summary),
      do: summary,
      else: build.(largest_fitting_take(build, 0, total, 0))
  end

  defp fits_frame?(summary), do: ResponseBudget.fits_payload?(%{ok: true, run: summary})

  defp largest_fitting_take(build, lo, hi, best) when lo <= hi do
    mid = div(lo + hi, 2)

    if fits_frame?(build.(mid)),
      do: largest_fitting_take(build, mid + 1, hi, mid),
      else: largest_fitting_take(build, lo, mid - 1, best)
  end

  defp largest_fitting_take(_build, _lo, _hi, best), do: best

  defp tail_summary(context, take) do
    {output, {next_seq, next_offset, remaining}, cut?} =
      take_segments(context.segments, take, context.position)

    cursor = OutputCursor.encode(context.scope, context.run.id, next_seq, next_offset, remaining)
    more? = cut? or context.read_more?

    # A terminal drain that reaches the end of persisted output still owing
    # events proves retention pruned rows mid-drain — end flagged, never clean.
    pruned? = not more? and Runs.terminal_status?(context.run.status) and remaining > 0

    context.run
    |> base_run_fields(context.subject)
    |> Map.put(:output, output)
    |> Map.put(:next, tail_next(context.run, more?, cursor))
    |> flag_output_gap(context.gap? or pruned?)
    |> Map.merge(context.structured_output)
    |> drop_nil_values()
  end

  defp flag_output_gap(summary, false), do: summary
  defp flag_output_gap(summary, true), do: Map.put(summary, :output_complete, false)

  defp base_run_fields(run, subject) do
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
      run_url: "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/runs/#{run.id}"
    }
  end

  defp drop_nil_values(map),
    do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  # Each event's still-undelivered bytes. The cursor's offset applies ONLY to the
  # event it names — if retention removed that event, its remaining bytes are
  # gone, so flag the gap rather than silently resuming at the next event.
  # Zero-length segments are kept so the cursor still advances past them.
  defp deliverable_segments(events, {from_seq, offset, _remaining}) do
    gap? = offset > 0 and not Enum.any?(events, &(&1.seq == from_seq))

    segments =
      Enum.map(events, fn event ->
        start = if event.seq == from_seq, do: offset, else: 0

        %{
          seq: event.seq,
          start: start,
          stream: event_stream(event),
          text: binary_from(get_chunk(event), start)
        }
      end)

    {segments, gap?}
  end

  # Take the first `limit` bytes across the segments, coalescing consecutive
  # same-stream text. A segment too large for the remaining room is FRAGMENTED
  # and its `{seq, offset}` carried in the cursor, so the next frame resumes
  # mid-event — output is never lost or duplicated. Each fully consumed event
  # decrements the cursor's owed-event count (a fragment doesn't, until done).
  defp take_segments(segments, limit, position) do
    {reversed, cursor, _room, cut?} =
      Enum.reduce_while(segments, {[], position, limit, false}, fn segment,
                                                                   {acc, cursor, room, _cut} ->
        {_seq, _offset, remaining} = cursor

        if byte_size(segment.text) <= room do
          {:cont,
           {prepend_output(acc, segment.stream, segment.text),
            {segment.seq + 1, 0, max(remaining - 1, 0)}, room - byte_size(segment.text), false}}
        else
          halt_fragment(acc, segment, remaining, room)
        end
      end)

    {Enum.reverse(reversed), cursor, cut?}
  end

  defp halt_fragment(acc, segment, remaining, room) do
    prefix = segment.text |> binary_part(0, room) |> trim_to_utf8_boundary()

    if prefix == "" do
      {:halt, {acc, {segment.seq, segment.start, remaining}, 0, true}}
    else
      {:halt,
       {prepend_output(acc, segment.stream, prefix),
        {segment.seq, segment.start + byte_size(prefix), remaining}, 0, true}}
    end
  end

  defp binary_from(text, 0), do: text

  defp binary_from(text, start) when start < byte_size(text),
    do: binary_part(text, start, byte_size(text) - start)

  defp binary_from(_text, _start), do: ""

  defp trim_to_utf8_boundary(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_to_utf8_boundary(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # A zero-length chunk carries no output, so it never becomes an element — but
  # the cursor still advances past it, so a run of empty chunks cannot stall.
  defp prepend_output(acc, _stream, ""), do: acc

  defp prepend_output([%{stream: stream, text: text} | rest], stream, chunk),
    do: [%{stream: stream, text: text <> chunk} | rest]

  defp prepend_output(acc, stream, chunk),
    do: [%{stream: stream, text: chunk} | acc]

  defp event_stream(event) do
    case event.stream || (event.payload && event.payload["stream"]) do
      "stderr" -> "stderr"
      _ -> "stdout"
    end
  end

  defp tail_next(run, more?, cursor) do
    cond do
      # Known backlog drains immediately. Checked BEFORE liveness: telling a
      # caller to long-poll for output the server already holds would block it
      # for the full window with nothing left to wake it.
      more? -> wait_next(run.id, cursor, "0")
      not Runs.terminal_status?(run.status) -> wait_next(run.id, cursor, "60s")
      true -> nil
    end
  end

  defp wait_next(run_id, cursor, timeout),
    do: %{tool: "wait_for_run", arguments: %{run_id: run_id, cursor: cursor, timeout: timeout}}

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
    if Runs.terminal_status?(status), do: complete?, else: nil
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

  defp fixed_run_next(
         %{id: run_id},
         _subject,
         %{structured_output_omitted: true},
         _tail_scope,
         _preview
       ),
       do: {%{tool: "wait_for_run", arguments: %{run_id: run_id, timeout: "0"}}, false}

  defp fixed_run_next(run, subject, _structured_output, tail_scope, preview) do
    cond do
      not Runs.terminal_status?(run.status) ->
        {live_snapshot_next(run.id, tail_scope), false}

      # A finished run whose preview left persisted output unshown is still
      # drainable — hand back a start cursor so the caller can stream the rest
      # instead of being stuck with the bounded tail preview.
      preview.persisted_omitted and is_binary(tail_scope) ->
        terminal_drain_next(run, subject, tail_scope)

      true ->
        {nil, false}
    end
  end

  # A terminal run cannot gain events, so the count captured here is exact. The
  # drain's cursor carries it down, decremented per delivered event, and a
  # nonzero remainder at the end of output proves retention pruned rows the
  # caller never saw — the drain then ends flagged instead of clean.
  #
  # The count runs AFTER the preview, so a zero count with an omission-flagged
  # preview positively proves retention emptied the run between the two reads.
  # Offering a drain then would sign a cursor whose empty result ends clean
  # while this very response shows preview content — mint nothing and mark the
  # output incomplete instead.
  defp terminal_drain_next(run, subject, scope) do
    {:ok, drainable} = Runs.count_progress_events_for_run(run.id, subject)

    if drainable > 0,
      do: {wait_next(run.id, OutputCursor.encode(scope, run.id, 0, 0, drainable), "0"), false},
      else: {nil, true}
  end

  # A live cursor asserts no owed-event minimum (remaining 0): retention only
  # prunes runs finished days ago, far beyond a live cursor's lifetime.
  defp live_snapshot_next(run_id, nil),
    do: %{tool: "wait_for_run", arguments: %{run_id: run_id, timeout: "60s"}}

  defp live_snapshot_next(run_id, scope),
    do: wait_next(run_id, OutputCursor.encode(scope, run_id, 0, 0, 0), "60s")

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
      {:ok, %{status: status}} -> Runs.terminal_status?(status)
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
      output_events_truncated: output_events_truncated?,
      # The preview's OWN omission: more persisted events than the window, or a
      # stream clipped by the byte cap. Deliberately EXCLUDES `run.*_truncated`
      # (the RUNNER's output cap) — those bytes were never persisted, so offering
      # to drain them would hand back a continuation with nothing behind it.
      persisted_omitted: output_events_truncated? or stdout_truncated? or stderr_truncated?
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
