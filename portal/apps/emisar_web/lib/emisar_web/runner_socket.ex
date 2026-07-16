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
       (`Runs.append_event_from_connection`, `Runs.finalize_from_connection`, etc)
       and routes
       outbound domain messages back as JSON envelopes.

  All envelopes carry `protocol_version: 1`. Unknown types are logged
  and ignored — never disconnected — so newer runners can talk to older
  clouds and vice versa.
  """

  @behaviour WebSock

  alias Emisar.{Catalog, Compat, Crypto, RequestContext, Runners, Runs}
  require Logger

  @protocol_version 1
  @heartbeat_timeout_ms 90_000
  @known_runner_message_types ~w(runner_state action_started action_progress action_result heartbeat error)
  @required_request_id_message_types ~w(action_started action_progress action_result)

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

    case Runners.connect_runner(runner) do
      {:ok, runner} ->
        state = connected_state(runner, token, request_context)
        Runners.subscribe_runner_transport(runner)
        Emisar.PubSub.subscribe(EmisarWeb.RunnerSocketDrain.drain_topic())
        Runners.audit_runner_connected(runner, token.id, request_context)
        {:ok, state}

      {:error, :already_connected} ->
        state = %{rejected?: true}

        {:stop, :normal,
         {1013,
          "This runner identity already has a live connection. Check for a cloned data directory."},
         state}

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
      heartbeat_ref: schedule_heartbeat_timeout()
    }
  end

  @impl true
  def handle_in(_frame, %{rejected?: true} = state), do: {:stop, :normal, state}

  def handle_in({raw, [opcode: :text]}, state) do
    if connection_owner?(state) do
      case Jason.decode(raw) do
        {:ok, %{"type" => type} = msg} ->
          handle_versioned_envelope(type, msg, state)

        {:ok, _} ->
          {:push, error_frame(nil, "bad_envelope", "missing type field"), state}

        {:error, _} ->
          {:push, error_frame(nil, "bad_envelope", "malformed JSON"), state}
      end
    else
      {:stop, :normal, {1008, "Runner connection ownership was superseded."}, state}
    end
  end

  def handle_in({_payload, [opcode: opcode]}, state) when opcode in [:binary, :ping, :pong] do
    {:ok, state}
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

  def terminate(reason, state) do
    case Runners.mark_disconnected(
           state.runner_id,
           state.connection_generation,
           state.connection_lease_id,
           format_reason(reason)
         ) do
      {:ok, _runner} ->
        Runners.audit_runner_disconnected(
          state.account_id,
          state.runner_id,
          format_reason(reason),
          state.request_context
        )

      {:error, :not_found} ->
        :ok
    end

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
        Logger.warning("runner_state ingest failed for #{state.runner_id}: #{inspect(reason)}")
        {:push, error_frame(nil, "runner_state_failed", to_string(inspect(reason))), state}
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
          Logger.error("finalize_from_connection failed: #{inspect(reason)}")
          {:push, error_frame(request_id, "finalize_failed", inspect(reason)), state}
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

  defp valid_envelope_request_id?(type, msg)
       when type in @required_request_id_message_types,
       do: Crypto.valid_run_request_id?(msg["request_id"])

  defp valid_envelope_request_id?("error", msg) do
    is_nil(msg["request_id"]) or Crypto.valid_run_request_id?(msg["request_id"])
  end

  defp valid_envelope_request_id?(_type, _msg), do: true

  # -- Version enforcement --------------------------------------------

  # Enforcement drops only a runner whose advertised version parses AND is
  # below the configured minimum; :unknown (missing/malformed), :outdated, and
  # :supported all proceed, as does warn-only mode — a stale-but-accepted
  # version surfaces in the console, it does not tear the socket down.
  defp maybe_enforce_runner_version(%Runners.Runner{} = runner, state) do
    if Compat.enforce_runners?() and Compat.runner_status(runner.runner_version) == :unsupported do
      reject_runner_version(runner, state)
    else
      reset_heartbeat_timeout(state)
      {:ok, refresh_heartbeat(state)}
    end
  end

  defp reject_runner_version(%Runners.Runner{} = runner, state) do
    minimum = Compat.runner_minimum()
    Runners.audit_runner_version_rejected(runner, minimum, state.request_context)

    shutdown = %{
      type: "shutdown",
      protocol_version: @protocol_version,
      reason: "runner_version_unsupported",
      message:
        "Runner version #{runner.runner_version} is below the minimum #{minimum} this control " <>
          "plane accepts. Upgrade the runner to reconnect."
    }

    send(self(), :stop_after_drain)
    {:push, {:text, Jason.encode!(shutdown)}, state}
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

  defp reset_heartbeat_timeout(state) do
    if ref = state[:heartbeat_ref], do: Process.cancel_timer(ref)
  end
end
