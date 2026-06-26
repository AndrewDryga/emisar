defmodule EmisarWeb.RunnerSocket do
  @moduledoc """
  WebSock handler implementing the runner ↔ cloud wire protocol.

  Each connection is one BEAM process. The process:

    1. Authenticates the runner on `init/1` using the bearer token (or
       bootstrap auth key) presented in the `Authorization` header,
       then ingests the runner's first `runner_state` message.
    2. Subscribes to the runner transport topic (`Runners.subscribe_runner_transport/1`) so the cloud can
       deliver `run_action`/`cancel`/`ack_result` messages to this
       socket by broadcasting onto that topic.
    3. Pushes Presence membership for the LiveView "online" indicator.
    4. Translates inbound JSON envelopes into domain calls
       (`Runs.append_event`, `Runs.mark_running`, etc) and routes
       outbound domain messages back as JSON envelopes.

  All envelopes carry `protocol_version: 1`. Unknown types are logged
  and ignored — never disconnected — so newer runners can talk to older
  clouds and vice versa.
  """

  @behaviour WebSock

  alias Emisar.{Catalog, RequestContext, Runners, Runs}
  require Logger

  @protocol_version 1
  @heartbeat_timeout_ms 90_000

  # -- WebSock callbacks ----------------------------------------------

  @impl true
  def init(%{token: %Runners.Token{} = token, runner: %Runners.Runner{} = runner} = upgrade) do
    # The connect request's IP + UA, carried on socket state so the
    # runner's own lifecycle events (connect / disconnect / error) stamp
    # them — and ONLY those. Engine work that happens to run in this
    # process (a runbook continuation wave) builds its own events with no
    # context, so the runner's connect metadata can't bleed onto them.
    request_context =
      RequestContext.new(%{ip_address: upgrade[:ip_address], user_agent: upgrade[:user_agent]})

    state = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      token_id: token.id,
      request_context: request_context,
      seen_request_ids: :queue.new(),
      seen_request_set: MapSet.new(),
      seen_request_count: 0,
      heartbeat_ref: schedule_heartbeat_timeout()
    }

    Runners.subscribe_runner_transport(runner)

    # Drain coordinator broadcasts here on SIGTERM so this process can
    # gracefully push a shutdown envelope to the runner before the
    # Endpoint tears the transport down.
    Emisar.PubSub.subscribe(EmisarWeb.RunnerSocketDrain.drain_topic())

    # Track this socket in presence (the live "online" signal) and stamp
    # last_connected_at. Presence — not a DB status column — is the
    # source of truth for "connected now"; it clears automatically when
    # this process dies. Catalog observation stays a separate concern.
    Runners.connect_runner(runner)
    Runners.audit_runner_connected(runner, token.id, request_context)

    # Recover any dispatch the *previous* socket dropped: this connection is now
    # subscribed to the runner's transport, so re-emit the runner's in-flight
    # runs and a lost run_action lands in ~instant instead of waiting for the
    # RunDispatchTimeout sweep. Deferred to handle_info so it runs after init
    # returns (off the connect path) and flows back through this live socket.
    send(self(), :redispatch_inflight)

    {:ok, state}
  end

  @impl true
  def handle_in({raw, [opcode: :text]}, state) do
    case Jason.decode(raw) do
      {:ok, %{"type" => type} = msg} ->
        if Map.get(msg, "protocol_version") in [nil, @protocol_version] do
          handle_envelope(type, msg, state)
        else
          {:push, error_frame(nil, "protocol_version_mismatch", "unsupported protocol_version"),
           state}
        end

      {:ok, _} ->
        {:push, error_frame(nil, "bad_envelope", "missing type field"), state}

      {:error, _} ->
        {:push, error_frame(nil, "bad_envelope", "malformed JSON"), state}
    end
  end

  def handle_in({_payload, [opcode: opcode]}, state) when opcode in [:binary, :ping, :pong] do
    {:ok, state}
  end

  @impl true
  def handle_info({:cloud_to_runner, msg}, state) do
    {:push, {:text, Jason.encode!(Map.put(msg, "protocol_version", @protocol_version))}, state}
  end

  def handle_info(:redispatch_inflight, state) do
    # Best-effort reconnect recovery — if it fails (e.g. a DB blip), log and
    # carry on; the RunDispatchTimeout sweep still backstops the in-flight runs,
    # so a recovery hiccup must not tear down an otherwise-healthy socket.
    try do
      Runs.redispatch_inflight_for_runner(state.runner_id)
    rescue
      error ->
        Logger.warning(
          "reconnect_redispatch failed runner=#{state.runner_id}: #{Exception.message(error)}"
        )
    end

    {:ok, state}
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

  # Sent by `Runners.broadcast_runner_revoked/1` after the runner is disabled or
  # deleted. Auth runs only at connect, so this is the kill switch for an already-
  # open socket: push a shutdown envelope, then stop — a revoked runner can no
  # longer finalize runs, append events, or mutate the pack-trust catalog.
  def handle_info(:runner_socket_revoked, state) do
    revoked = %{
      type: "shutdown",
      protocol_version: @protocol_version,
      reason: "runner_revoked",
      message: "This runner was disabled or removed. Disconnecting."
    }

    send(self(), :stop_after_drain)
    {:push, {:text, Jason.encode!(revoked)}, state}
  end

  def handle_info(other, state) do
    Logger.debug("runner_socket #{state.runner_id} unhandled message: #{inspect(other)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Runners.mark_disconnected(state.runner_id, format_reason(reason))

    Runners.audit_runner_disconnected(
      state.account_id,
      state.runner_id,
      format_reason(reason),
      state.request_context
    )

    :ok
  end

  # Normalize the IP `RunnerConnectController.ip_string/1` passes via socket
  # state: drop its "unknown" sentinel (emitted when `conn.remote_ip` isn't a
  # real tuple), and strip the `::ffff:` IPv4-mapped-IPv6 wrapper an IPv6
  # listener surfaces — so a runner's audit IP reads `1.2.3.4`, the same form
  # `EmisarWeb.RequestContext` records for every browser path.
  @doc false
  def normalize_ip("unknown"), do: nil
  def normalize_ip("::ffff:" <> ip4), do: ip4
  def normalize_ip(s) when is_binary(s), do: s
  def normalize_ip(_), do: nil

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

  defp truncate_reason(s),
    do: binary_part(s, 0, @reason_limit) <> "…"

  # -- Envelope dispatch ----------------------------------------------

  defp handle_envelope("runner_state", msg, state) do
    case Catalog.observe_state(state.runner_id, msg) do
      {:ok, _runner} ->
        # connect_runner already fired at socket init; this just refreshes
        # the heartbeat-timeout watcher now that we have a catalog.
        reset_heartbeat_timeout(state)
        {:ok, refresh_heartbeat(state)}

      {:error, reason} ->
        Logger.warning("runner_state ingest failed for #{state.runner_id}: #{inspect(reason)}")
        {:push, error_frame(nil, "runner_state_failed", to_string(inspect(reason))), state}
    end
  end

  defp handle_envelope("action_progress", msg, state) do
    # `chunk` + `stream` go inside `payload` because that's what the
    # `action_run_events` schema actually persists. Earlier versions
    # set top-level `chunk:` which Ecto silently dropped on insert.
    payload = %{
      "chunk" => msg["chunk"],
      "stream" => msg["stream"]
    }

    with {:ok, run_id} <- fetch_run_id(msg["request_id"], state),
         {:ok, _event} <-
           Runs.append_event(run_id, %{
             kind: "progress",
             seq: msg["seq"],
             stream: msg["stream"],
             payload: payload
           }) do
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
    if already_seen?(msg["request_id"], state) do
      {:push, ack_result_frame(msg["request_id"]), state}
    else
      case Runs.finalize_from_result(state.runner_id, msg) do
        {:ok, _run} ->
          # Remember only AFTER the result is durably persisted, so a transient
          # finalize failure (below) leaves the request un-acked and the
          # runner's retry re-finalizes instead of being silently deduped.
          {:push, ack_result_frame(msg["request_id"]), remember_request(msg["request_id"], state)}

        {:error, :unknown_request_id} ->
          Logger.warning(
            "runner #{state.runner_id} sent result for unknown/foreign request_id #{msg["request_id"]}"
          )

          # Genuinely terminal (no matching run) — remember so we don't reprocess.
          {:push, ack_result_frame(msg["request_id"]), remember_request(msg["request_id"], state)}

        {:error, reason} ->
          # Transient persist failure — do NOT remember; the runner retries.
          Logger.error("finalize_from_result failed: #{inspect(reason)}")
          {:push, error_frame(msg["request_id"], "finalize_failed", inspect(reason)), state}
      end
    end
  end

  defp handle_envelope("heartbeat", msg, state) do
    Runners.record_heartbeat(state.account_id, state.runner_id, msg["action_load"])
    {:ok, refresh_heartbeat(state)}
  end

  defp handle_envelope("error", msg, state) do
    Runners.audit_runner_error(
      state.account_id,
      state.runner_id,
      %{code: msg["code"], message: msg["message"], request_id: msg["request_id"]},
      state.request_context
    )

    {:ok, state}
  end

  defp handle_envelope(type, _msg, state) do
    Logger.debug("runner_socket unknown envelope type #{type}")
    {:ok, state}
  end

  # -- Helpers --------------------------------------------------------

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

  defp error_frame(request_id, code, message) do
    payload = %{
      type: "error",
      protocol_version: @protocol_version,
      code: code,
      message: message
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

  defp already_seen?(nil, _state), do: false

  defp already_seen?(request_id, state) do
    MapSet.member?(state.seen_request_set, request_id)
  end

  defp remember_request(nil, state), do: state

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

  defp reset_heartbeat_timeout(state) do
    if ref = state[:heartbeat_ref], do: Process.cancel_timer(ref)
  end
end
