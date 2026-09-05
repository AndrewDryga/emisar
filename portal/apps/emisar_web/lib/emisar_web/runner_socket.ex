defmodule EmisarWeb.RunnerSocket do
  @moduledoc """
  WebSock handler implementing the runner ↔ cloud wire protocol.

  Each connection is one BEAM process. The process:

    1. Authenticates the runner on `init/1` using the bearer token (or
       bootstrap enrollment key) presented in the `Authorization` header,
       then ingests the runner's first `runner_state` message.
    2. Subscribes to the runner transport topic (`Runners.subscribe_runner_transport/1`) so the cloud can
       deliver `run_action`/`cancel`/`ack_result` messages to this
       socket by broadcasting onto that topic.
    3. Pushes Presence membership for the LiveView "online" indicator.
    4. Translates inbound JSON envelopes into domain calls
       (`Runs.append_event_from_connection`, `Runs.finalize_from_connection`, etc)
       and routes
       outbound domain messages back as JSON envelopes.

  All envelopes carry `protocol_version: 1`. Unknown types are logged
  and ignored — never disconnected — so newer runners can talk to older
  clouds and vice versa.
  """

  @behaviour WebSock

  alias Emisar.{Accounts, Catalog, Crypto, JSONValue, RequestContext, Runners, Runs}
  require Logger

  @protocol_version 1
  @heartbeat_timeout_ms 90_000

  # The wire contract bounds JSON nesting at 64 and the runner enforces exactly
  # that on the frames IT receives (`runner/internal/cloud/protocol.go`,
  # `jsonvalue.Limits{MaxDepth: 64}`); this is the portal half, which decoded
  # a runner's frame with no structural bound at all. `JSONValue.validate/2`
  # takes both bounds, and the node one is the ceiling the 2 MiB
  # `max_frame_size` already implies: the cheapest node costs two bytes.
  @max_frame_depth 64
  @max_frame_nodes 1_048_576
  @known_runner_message_types ~w(runner_state action_started action_progress action_result heartbeat error)
  @required_request_id_message_types ~w(action_started action_progress action_result)

  # -- WebSock callbacks ----------------------------------------------

  @impl true
  def init(%{token: %Runners.Token{} = token, runner: %Runners.Runner{} = runner} = upgrade) do
    # The connect request's IP + UA, carried on socket state so the
    # runner's own lifecycle events (connect / disconnect / error) stamp
    # them — and ONLY those. Engine work that happens to run in this
    # process (a runbook scheduler callback) builds its own events with no
    # context, so the runner's connect metadata can't bleed onto them.
    request_context =
      RequestContext.new(%{ip_address: upgrade[:ip_address], user_agent: upgrade[:user_agent]})

    Accounts.subscribe_account_lifecycle(runner.account_id)

    case Runners.connect_runner(runner, token.id, request_context) do
      {:ok, runner} ->
        state = connected_state(runner, token, request_context)
        Runners.subscribe_runner_transport(runner)
        Emisar.PubSub.subscribe(EmisarWeb.RunnerSocketDrain.drain_topic())
        {:ok, state}

      {:error, :already_connected} ->
        state = %{rejected?: true}

        {:stop, :normal,
         {1013,
          "This runner identity already has a live connection. Check for a cloned data directory."},
         state}

      {:error, :account_disabled} ->
        state = %{account_id: runner.account_id, pending_account_disabled?: true}
        send(self(), {:account_disabled, runner.account_id})
        {:ok, state}

      {:error, reason} ->
        Logger.error("runner connection claim failed runner=#{runner.id}: #{inspect(reason)}")

        {:stop, :normal, {1011, "Could not establish runner connection ownership."},
         %{rejected?: true}}
    end
  end

  defp connected_state(runner, token, request_context) do
    %{
      account_id: runner.account_id,
      runner_id: runner.id,
      connection_generation: runner.connection_generation,
      connection_lease_id: runner.connection_lease_id,
      token_id: token.id,
      request_context: request_context,
      seen_request_ids: :queue.new(),
      seen_request_set: MapSet.new(),
      seen_request_count: 0,
      error_frames: 0,
      runner_state_frames: 0,
      heartbeat_ref: schedule_heartbeat_timeout()
    }
  end

  # Every `error` frame writes a durable audit row stamped with the plan's
  # retention horizon. A runner is authenticated but treated as hostile (the
  # host is the trust anchor), and nothing bounded this: a loop of error frames
  # buried the account's own action_run.* rows, drowned the SIEM export, and
  # grew the audit table without limit. The adjacent progress path has had a
  # durable budget for exactly this reason. Beyond the cap the connection is
  # dropped rather than silently ignored — a runner emitting this many distinct
  # errors on one connection is broken either way, and a reconnect gets a fresh
  # budget so an honest flapping host still reports.
  @max_error_frames_per_connection 100

  # Every `runner_state` frame parses up to 2 MiB and runs a multi-row catalog
  # upsert transaction against the shared database, then resumes the runner's
  # runs — the most expensive thing a runner can ask for, and until now the only
  # hostile-input path on this socket with no bound at all. An honest runner
  # sends one per connect plus one per pack reload or availability flip, so the
  # same budget the error frames get is two orders of magnitude of headroom, and
  # a reconnect refreshes it exactly as it does there.
  @max_runner_state_frames_per_connection 100

  @impl true
  def handle_in(_frame, %{rejected?: true} = state), do: {:stop, :normal, state}
  def handle_in(_frame, %{pending_account_disabled?: true} = state), do: {:stop, :normal, state}

  def handle_in({raw, [opcode: :text]}, state) do
    if connection_owner?(state) do
      case decode_frame(raw) do
        {:ok, %{"type" => type} = msg} ->
          handle_versioned_envelope(type, msg, state)

        _ ->
          {:push, error_frame(nil, "bad_envelope"), state}
      end
    else
      {:stop, :normal, {1008, "Runner connection ownership was superseded."}, state}
    end
  end

  def handle_in({_payload, [opcode: opcode]}, state) when opcode in [:binary, :ping, :pong] do
    {:ok, state}
  end

  defp decode_frame(raw) do
    with {:ok, msg} <- Jason.decode(raw),
         :ok <- JSONValue.validate(msg, max_depth: @max_frame_depth, max_nodes: @max_frame_nodes) do
      {:ok, msg}
    end
  end

  defp handle_versioned_envelope(type, msg, state)
       when type in @known_runner_message_types do
    cond do
      Map.get(msg, "protocol_version") != @protocol_version ->
        {:stop, :normal, {1002, "Unsupported runner protocol_version."}, state}

      not valid_envelope_request_id?(type, msg) ->
        {:stop, :normal, {1002, "Invalid #{type} request_id."}, state}

      true ->
        handle_envelope(type, msg, state)
    end
  end

  defp handle_versioned_envelope(type, msg, state), do: handle_envelope(type, msg, state)

  @impl true
  def handle_info(_message, %{rejected?: true} = state), do: {:stop, :normal, state}

  def handle_info({:account_disabled, account_id}, %{account_id: account_id} = state) do
    disabled = %{
      type: "shutdown",
      protocol_version: @protocol_version,
      reason: "account_disabled",
      message: "This account is disabled. The runner will retry after it is enabled."
    }

    send(self(), :stop_after_drain)
    {:push, {:text, Jason.encode!(disabled)}, state}
  end

  def handle_info({:cloud_to_runner, expected_generation, msg}, state) do
    cond do
      expected_generation != state.connection_generation ->
        {:ok, state}

      connection_owner?(state) ->
        {:push, {:text, Jason.encode!(Map.put(msg, "protocol_version", @protocol_version))},
         state}

      true ->
        {:stop, :normal, {1008, "Runner connection ownership was superseded."}, state}
    end
  end

  def handle_info(:resume_runs, state) do
    if connection_owner?(state) do
      Runs.resume_runs_for_runner(state.runner_id)
      {:ok, state}
    else
      {:stop, :normal, {1008, "Runner connection ownership was superseded."}, state}
    end
  end

  def handle_info(:dispatch_queued, state) do
    if connection_owner?(state) do
      Runs.dispatch_queued_for_runner(state.runner_id)
      {:ok, state}
    else
      {:stop, :normal, {1008, "Runner connection ownership was superseded."}, state}
    end
  end

  def handle_info(:heartbeat_timeout, state) do
    Logger.warning("runner #{state.runner_id} missed heartbeat — closing socket")
    {:stop, :normal, state}
  end

  # Sent by `EmisarWeb.RunnerSocketDrain.terminate/2` on SIGTERM. Push
  # a `shutdown` envelope so the runner can resync after reconnect (its
  # outbound queue is per-connection — stale messages after the cloud
  # restart would be replayed against new state otherwise), then stop
  # normally. The drain GenServer sleeps briefly afterward so this
  # frame is on the wire before the Endpoint closes the transport.
  def handle_info(:runner_socket_drain, state) do
    shutdown = %{
      type: "shutdown",
      protocol_version: @protocol_version,
      reason: "cloud_shutdown",
      message: "Cloud is shutting down. Reconnect to resync."
    }

    # Schedule the stop AFTER the frame is queued so WebSock pushes the
    # shutdown envelope before the transport teardown.
    send(self(), :stop_after_drain)
    {:push, {:text, Jason.encode!(shutdown)}, state}
  end

  def handle_info(:stop_after_drain, state), do: {:stop, :normal, state}

  # Disable closes the active socket but keeps the credential retryable so enable
  # can restore service without touching the host.
  def handle_info(:runner_socket_disabled, state) do
    disabled = %{
      type: "shutdown",
      protocol_version: @protocol_version,
      reason: "runner_disabled",
      message: "This runner is disabled. Waiting until it is enabled."
    }

    send(self(), :stop_after_drain)
    {:push, {:text, Jason.encode!(disabled)}, state}
  end

  # Delete revokes the identity. The terminal frame stops the host before it can
  # retry a credential the portal will no longer accept.
  def handle_info(:runner_socket_revoked, state) do
    revoked = %{
      type: "shutdown",
      protocol_version: @protocol_version,
      reason: "runner_revoked",
      message: "This runner was removed. Disconnecting."
    }

    send(self(), :stop_after_drain)
    {:push, {:text, Jason.encode!(revoked)}, state}
  end

  def handle_info({:runner_socket_superseded, lease_id}, state)
      when lease_id != state.connection_lease_id do
    {:stop, :normal, {1008, "Runner identity connected from another process."}, state}
  end

  def handle_info({:runner_socket_superseded, _own_lease_id}, state), do: {:ok, state}

  def handle_info(other, state) do
    Logger.debug("runner_socket #{state.runner_id} unhandled message: #{inspect(other)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{rejected?: true}), do: :ok
  def terminate(_reason, %{pending_account_disabled?: true}), do: :ok

  def terminate(reason, state) do
    # A superseded lease is {:error, :not_found} — the successor owns the
    # lifecycle now, so this socket's close stamps and audits nothing.
    _ =
      Runners.disconnect_runner(
        state.runner_id,
        state.connection_generation,
        state.connection_lease_id,
        format_reason(reason),
        state.request_context
      )

    :ok
  end

  # `last_disconnect_reason` is varchar(255) — Bandit's terminate reason
  # for an abnormal close can be a giant tuple (full protocol error +
  # stacktrace + Plug.Conn), so trim to fit the column. The first 240
  # bytes are the actionable bit (atom + module + line); the rest is
  # noise we already have via Sentry / Logger.
  @reason_limit 240

  defp format_reason(:normal), do: "normal"
  defp format_reason({:shutdown, r}), do: truncate_reason("shutdown:#{inspect(r)}")
  defp format_reason(other), do: truncate_reason(inspect(other))

  defp truncate_reason(s) when byte_size(s) <= @reason_limit, do: s

  defp truncate_reason(s) do
    prefix = s |> binary_part(0, @reason_limit) |> trim_to_utf8_boundary()
    prefix <> "…"
  end

  defp trim_to_utf8_boundary(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_to_utf8_boundary(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # -- Envelope dispatch ----------------------------------------------

  defp handle_envelope("runner_state", _msg, %{runner_state_frames: seen} = state)
       when seen >= @max_runner_state_frames_per_connection do
    Logger.warning("runner #{state.runner_id} exceeded the per-connection runner_state budget")
    {:stop, :normal, {1008, "Too many runner_state frames on one connection."}, state}
  end

  defp handle_envelope("runner_state", msg, state) do
    state = %{state | runner_state_frames: state.runner_state_frames + 1}

    case Catalog.observe_state_from_connection(
           state.runner_id,
           msg,
           state.connection_generation,
           state.connection_lease_id
         ) do
      {:ok, runner} ->
        # connect_runner already fired at socket init; this just refreshes
        # the heartbeat-timeout watcher now that we have a catalog. The
        # runner's version is first known here (it rides runner_state, not the
        # connect upgrade), so version enforcement gates on it now.
        case maybe_enforce_runner_version(runner, state) do
          {:ok, _new_state} = result ->
            send(self(), :resume_runs)
            result

          other ->
            other
        end

      {:error, reason} ->
        Logger.warning(
          "runner_state ingest failed for #{state.runner_id}: #{failure_diagnostic(reason)}"
        )

        {:push, error_frame(nil, "runner_state_failed"), state}
    end
  end

  defp handle_envelope("action_started", msg, state) do
    case Runs.mark_started_from_connection(
           state.account_id,
           state.runner_id,
           state.connection_generation,
           state.connection_lease_id,
           msg["request_id"]
         ) do
      {:ok, _run} ->
        {:ok, state}

      {:error, reason} when reason in [:unknown_request_id, :not_dispatchable] ->
        {:ok, state}

      {:error, :connection_superseded} ->
        {:stop, :normal, {1008, "Runner connection ownership was superseded."}, state}

      {:error, reason} ->
        Logger.error("mark_started_from_connection failed: #{inspect(reason)}")
        {:stop, {:action_started_persist_failed, reason}, state}
    end
  end

  defp handle_envelope("action_progress", msg, state) do
    # `chunk` + `stream` go inside `payload`, matching the persisted event shape.
    payload = %{
      "chunk" => msg["chunk"],
      "stream" => msg["stream"]
    }

    with {:ok, run_id} <- fetch_run_id(msg["request_id"], state),
         {:ok, _event} <-
           Runs.append_event_from_connection(
             run_id,
             %{
               kind: "progress",
               seq: msg["seq"],
               stream: msg["stream"],
               payload: payload
             },
             state.account_id,
             state.runner_id,
             state.connection_generation,
             state.connection_lease_id
           ) do
      {:ok, state}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        # A malformed/unpersistable progress chunk — log it so genuine schema
        # drift surfaces instead of vanishing. (A re-sent duplicate seq is
        # classified :duplicate_event by Runs.append_event and drops quietly below.)
        Logger.warning(
          "runner #{state.runner_id} dropped an invalid action_progress chunk: #{inspect(changeset.errors)}"
        )

        {:ok, state}

      _ ->
        # Foreign/unknown request_id, an already-finalized run, or a duplicate
        # re-sent chunk — all benign; drop quietly.
        {:ok, state}
    end
  end

  defp handle_envelope("action_result", msg, state) do
    request_id = msg["request_id"]

    if already_seen?(request_id, state) do
      {:push, ack_result_frame(request_id), state}
    else
      case Runs.finalize_from_connection(
             state.account_id,
             state.runner_id,
             state.connection_generation,
             state.connection_lease_id,
             msg
           ) do
        {:ok, _run} ->
          # Remember only AFTER the result is durably persisted, so a transient
          # finalize failure leaves the request un-acked and retryable.
          send(self(), :dispatch_queued)
          {:push, ack_result_frame(request_id), remember_request(request_id, state)}

        {:error, :unknown_request_id} ->
          Logger.warning(
            "runner #{state.runner_id} sent result for unknown/foreign request_id #{request_id}"
          )

          {:push, ack_result_frame(request_id), remember_request(request_id, state)}

        {:error, reason} ->
          # Transient persist failure — do NOT remember; the runner retries.
          Logger.error("finalize_from_connection failed: #{failure_diagnostic(reason)}")
          {:push, error_frame(request_id, "finalize_failed"), state}
      end
    end
  end

  defp handle_envelope("heartbeat", msg, state) do
    case Runners.record_heartbeat(
           state.account_id,
           state.runner_id,
           state.connection_generation,
           state.connection_lease_id,
           msg["action_load"]
         ) do
      {:ok, _runner} -> {:ok, refresh_heartbeat(state)}
      {:error, :not_found} -> {:stop, :normal, {1008, "Runner connection lease expired."}, state}
      {:error, reason} -> {:stop, {:heartbeat_persist_failed, reason}, state}
    end
  end

  # `concurrency_cap_reached` is not an error report — it is the wire contract's
  # back-pressure answer to a dispatch WE sent, and the portal requeues the run
  # on it. A saturated runner answering exactly as the contract requires must
  # never look like an error flood, so a refusal the domain CORRELATED to a run
  # we dispatched to this runner is exempt from the budget (that rate is bounded
  # by our own dispatch rate, not by the runner). A refusal naming a request the
  # runner was never sent is not back-pressure at all — it is a claim the runner
  # can invent forever — so it spends the budget like any other error frame.
  defp handle_envelope("error", %{"code" => "concurrency_cap_reached"} = msg, state) do
    case record_runner_error(msg, state) do
      {:ok, :request_not_found} -> spend_error_frame(state)
      {:ok, _outcome} -> {:ok, state}
      {:stop, _reason, _state} = stop -> stop
    end
  end

  defp handle_envelope("error", msg, state) do
    with {:ok, state} <- spend_error_frame(state),
         {:ok, _outcome} <- record_runner_error(msg, state) do
      {:ok, state}
    end
  end

  defp handle_envelope(type, _msg, state) do
    Logger.debug("runner_socket unknown envelope type #{type}")
    {:ok, state}
  end

  defp spend_error_frame(%{error_frames: seen} = state)
       when seen >= @max_error_frames_per_connection do
    Logger.warning("runner #{state.runner_id} exceeded the per-connection error-frame budget")
    {:stop, :normal, {1008, "Too many error frames on one connection."}, state}
  end

  defp spend_error_frame(state), do: {:ok, %{state | error_frames: state.error_frames + 1}}

  # Returns the domain outcome so the caller can judge the frame, or the socket
  # result that ends the connection when nothing could be persisted.
  defp record_runner_error(msg, state) do
    runner_error =
      Runs.build_runner_error(
        state.account_id,
        state.runner_id,
        %{code: msg["code"], message: msg["message"], request_id: msg["request_id"]},
        state.request_context
      )

    case Runs.handle_runner_error(runner_error) do
      {:ok, outcome} ->
        {:ok, outcome}

      {:error, reason} ->
        failure = runner_error_failure(reason)
        Logger.error("handle_runner_error failed for #{state.runner_id}: #{failure}")
        {:stop, {:runner_error_persist_failed, failure}, state}
    end
  end

  defp runner_error_failure(%Ecto.Changeset{}), do: :invalid_audit_event
  defp runner_error_failure(_reason), do: :persistence_error

  # A failure reason can CARRY the runner's own bytes — an oversized
  # `action_result` field lands in the rejecting changeset's `changes` — so a
  # portal diagnostic names the shape and never inspects the value. Changeset
  # errors are portal-authored field/message pairs, and `{:invalid_catalog, _}`
  # carries a portal-authored sentence; everything else is categorized.
  defp failure_diagnostic(%Ecto.Changeset{} = changeset),
    do: "invalid: #{inspect(changeset.errors)}"

  defp failure_diagnostic({:invalid_catalog, message}), do: "invalid_catalog: #{message}"
  defp failure_diagnostic(reason) when is_atom(reason), do: to_string(reason)
  defp failure_diagnostic(_reason), do: "unrecognized failure"

  defp valid_envelope_request_id?(type, msg)
       when type in @required_request_id_message_types,
       do: Crypto.valid_run_request_id?(msg["request_id"])

  defp valid_envelope_request_id?("error", msg) do
    is_nil(msg["request_id"]) or Crypto.valid_run_request_id?(msg["request_id"])
  end

  defp valid_envelope_request_id?(_type, _msg), do: true

  # -- Version enforcement --------------------------------------------

  # The rejection decision and its audit live in the domain
  # (`Runners.enforce_runner_version/2`); this only maps the outcome to a
  # shutdown frame.
  defp maybe_enforce_runner_version(%Runners.Runner{} = runner, state) do
    case Runners.enforce_runner_version(runner, state.request_context) do
      :ok ->
        {:ok, refresh_heartbeat(state)}

      {:error, {:unsupported_version, minimum}} ->
        shutdown = %{
          type: "shutdown",
          protocol_version: @protocol_version,
          reason: "runner_version_unsupported",
          message:
            "Runner version #{runner.runner_version} is below the minimum #{minimum} this " <>
              "control plane accepts. Upgrade the runner to reconnect."
        }

        send(self(), :stop_after_drain)
        {:push, {:text, Jason.encode!(shutdown)}, state}
    end
  end

  # -- Helpers --------------------------------------------------------

  defp connection_owner?(state) do
    Runners.connection_owner?(
      state.account_id,
      state.runner_id,
      state.connection_generation,
      state.connection_lease_id
    )
  end

  defp fetch_run_id(nil, _state), do: :error

  defp fetch_run_id(request_id, state) do
    # Scoped by runner_id so a malicious runner in the same account can't
    # write progress chunks against another runner's run.
    case Runs.fetch_run_by_request_id_for_runner(request_id, state.runner_id) do
      {:error, :not_found} -> :error
      {:ok, run} -> {:ok, run.id}
    end
  end

  defp ack_result_frame(request_id) do
    {:text,
     Jason.encode!(%{
       type: "ack_result",
       protocol_version: @protocol_version,
       request_id: request_id
     })}
  end

  # Portal→runner error text is FIXED per code, never derived from a failure
  # reason: the reason can embed the runner's own bytes, and this frame goes
  # straight back on the wire and into the runner's log. `Map.fetch!` keeps the
  # set closed — a new code declares its message here or the frame raises.
  @error_messages %{
    "bad_envelope" => "The portal could not read this message.",
    "runner_state_failed" => "The portal could not process the runner state.",
    "finalize_failed" => "The portal could not persist this action result. The runner will retry."
  }

  defp error_frame(request_id, code) do
    payload = %{
      type: "error",
      protocol_version: @protocol_version,
      code: code,
      message: Map.fetch!(@error_messages, code)
    }

    payload = if request_id, do: Map.put(payload, :request_id, request_id), else: payload
    {:text, Jason.encode!(payload)}
  end

  # request_id dedup: bounded FIFO + Set for O(1) membership. Keeps the
  # most recent 5_000 IDs in memory — enough for ack-replay storms during
  # reconnect, not enough to bloat a long-lived socket process. The count
  # is tracked in state (not `:queue.len/1`, which is O(n)) so eviction
  # stays O(1) on a long-lived socket past capacity.
  @dedup_capacity 5_000

  defp already_seen?(request_id, state) do
    MapSet.member?(state.seen_request_set, request_id)
  end

  defp remember_request(request_id, state) do
    if MapSet.member?(state.seen_request_set, request_id) do
      state
    else
      queue = :queue.in(request_id, state.seen_request_ids)
      set = MapSet.put(state.seen_request_set, request_id)
      count = state.seen_request_count + 1

      if count > @dedup_capacity do
        {{:value, evict}, trimmed_queue} = :queue.out(queue)

        %{
          state
          | seen_request_ids: trimmed_queue,
            seen_request_set: MapSet.delete(set, evict),
            seen_request_count: count - 1
        }
      else
        %{state | seen_request_ids: queue, seen_request_set: set, seen_request_count: count}
      end
    end
  end

  defp schedule_heartbeat_timeout do
    Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout_ms)
  end

  defp refresh_heartbeat(state) do
    reset_heartbeat_timeout(state)
    %{state | heartbeat_ref: schedule_heartbeat_timeout()}
  end

  # Cancel AND flush. `Process.cancel_timer/1` returns false when the timer
  # already fired, and by then `:heartbeat_timeout` is sitting in our mailbox —
  # frames and timer messages share it, so a heartbeat that arrived while we were
  # busy (persisting the previous one) got processed first, refreshed the timer,
  # and then the stale timeout closed a socket whose runner was answering. The
  # selective receive drops that message; `after 0` keeps it non-blocking, since
  # a genuinely-cancelled timer has nothing to flush.
  defp reset_heartbeat_timeout(%{heartbeat_ref: ref}) when is_reference(ref) do
    unless Process.cancel_timer(ref) do
      receive do
        :heartbeat_timeout -> :ok
      after
        0 -> :ok
      end
    end

    :ok
  end

  defp reset_heartbeat_timeout(_state), do: :ok
end
