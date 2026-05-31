defmodule EmisarWeb.RunnerSocket do
  @moduledoc """
  WebSock handler implementing the runner ↔ cloud wire protocol.

  Each connection is one BEAM process. The process:

    1. Authenticates the runner on `init/1` using the bearer token (or
       bootstrap auth key) presented in the `Authorization` header,
       then ingests the runner's first `runner_state` message.
    2. Subscribes to `Emisar.PubSub.topic_for_runner/1` so the cloud can
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

  require Logger

  alias Emisar.{Runners, Audit, Catalog, PubSub, Runs}
  alias Emisar.Runners.{Runner, Token}
  alias EmisarWeb.RunnerPresence

  @protocol_version 1
  @heartbeat_timeout_ms 90_000

  # -- WebSock callbacks ----------------------------------------------

  @impl true
  def init(%{token: %Token{} = token, runner: %Runner{} = runner} = upgrade) do
    # Stash IP + UA from the HTTP upgrade on the socket process so
    # every Audit.log call in init / terminate / handle_in carries
    # them. The controller passed these in via `WebSockAdapter.upgrade`.
    Audit.put_request_metadata(%{
      ip_address: upgrade[:ip_address],
      user_agent: upgrade[:user_agent]
    })

    state = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      token_id: token.id,
      seen_request_ids: :queue.new(),
      seen_request_set: MapSet.new(),
      heartbeat_ref: schedule_heartbeat_timeout()
    }

    PubSub.subscribe_runner(runner.id)
    {:ok, _} = RunnerPresence.track_runner(self(), runner.account_id, runner.id)

    # Flip status to "connected" the moment the WebSocket auth handshake
    # succeeds. Previously the row stayed "pending" until the first
    # `runner_state` envelope arrived — which made a row look offline in
    # the operator UI even while Presence already showed it online, and
    # gave a runner an indefinite stuck-at-pending window if catalog
    # ingestion errored. Catalog observation stays a separate concern.
    Runners.mark_connected(runner.id)

    Audit.log(runner.account_id, "runner.connected",
      actor_kind: "runner",
      actor_id: runner.id,
      actor_label: runner.name,
      subject_kind: "runner",
      subject_id: runner.id,
      subject_label: runner.name,
      payload: %{token_id: token.id}
    )

    {:ok, state}
  end

  @impl true
  def handle_in({raw, [opcode: :text]}, state) do
    case Jason.decode(raw) do
      {:ok, %{"type" => type} = msg} ->
        if Map.get(msg, "protocol_version") in [nil, @protocol_version] do
          handle_envelope(type, msg, state)
        else
          {:push, error_frame(nil, "protocol_version_mismatch",
             "unsupported protocol_version"), state}
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

  def handle_info(:heartbeat_timeout, state) do
    Logger.warning("runner #{state.runner_id} missed heartbeat — closing socket")
    {:stop, :normal, state}
  end

  def handle_info(other, state) do
    Logger.debug("runner_socket #{state.runner_id} unhandled message: #{inspect(other)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Runners.mark_disconnected(state.runner_id, format_reason(reason))

    Audit.log(state.account_id, "runner.disconnected",
      actor_kind: "runner",
      actor_id: state.runner_id,
      subject_kind: "runner",
      subject_id: state.runner_id,
      payload: %{reason: format_reason(reason)}
    )

    :ok
  end

  # If `ip_key/1` returns the rate-limiter's "unknown" sentinel, treat
  # it as no IP for audit so we don't pollute rows with the placeholder.
  # (This helper is used by RunnerConnectController.)
  @doc false
  def normalize_ip("unknown"), do: nil
  def normalize_ip(s) when is_binary(s), do: s
  def normalize_ip(_), do: nil

  defp format_reason(:normal), do: "normal"
  defp format_reason({:shutdown, r}), do: "shutdown:#{inspect(r)}"
  defp format_reason(other), do: inspect(other)

  # -- Envelope dispatch ----------------------------------------------

  defp handle_envelope("runner_state", msg, state) do
    case Catalog.observe_state(state.runner_id, msg) do
      {:ok, _runner} ->
        # mark_connected already fired at socket init; this just refreshes
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
      _ -> {:ok, state}
    end
  end

  defp handle_envelope("action_result", msg, state) do
    if already_seen?(msg["request_id"], state) do
      {:push, ack_result_frame(msg["request_id"]), state}
    else
      state = remember_request(msg["request_id"], state)

      case Runs.finalize_from_result(state.runner_id, msg) do
        {:ok, _run} ->
          {:push, ack_result_frame(msg["request_id"]), state}

        {:error, :unknown_request_id} ->
          Logger.warning(
            "runner #{state.runner_id} sent result for unknown/foreign request_id #{msg["request_id"]}"
          )

          {:push, ack_result_frame(msg["request_id"]), state}

        {:error, reason} ->
          Logger.error("finalize_from_result failed: #{inspect(reason)}")
          {:push, error_frame(msg["request_id"], "finalize_failed", inspect(reason)), state}
      end
    end
  end

  defp handle_envelope("heartbeat", msg, state) do
    Runners.record_heartbeat(state.runner_id, msg["action_load"])
    {:ok, refresh_heartbeat(state)}
  end

  defp handle_envelope("error", msg, state) do
    Audit.log(state.account_id, "runner.error",
      actor_kind: "runner",
      actor_id: state.runner_id,
      subject_kind: "runner",
      subject_id: state.runner_id,
      payload: %{
        code: msg["code"],
        message: msg["message"],
        request_id: msg["request_id"]
      }
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
  # reconnect, not enough to bloat a long-lived socket process.
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
      q = :queue.in(request_id, state.seen_request_ids)
      set = MapSet.put(state.seen_request_set, request_id)

      if :queue.len(q) > @dedup_capacity do
        {{:value, evict}, q2} = :queue.out(q)
        %{state | seen_request_ids: q2, seen_request_set: MapSet.delete(set, evict)}
      else
        %{state | seen_request_ids: q, seen_request_set: set}
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
