defmodule EmisarWeb.RunnerPresence do
  @moduledoc """
  Phoenix.Presence tracking of currently-connected runners, scoped by
  account. Used by LiveView to flip the "online" dot without polling.

  Tracked metadata is intentionally small: pid + connected_at. Runner
  state details live in the DB (`Emisar.Runners.Runner`) since they
  outlive the websocket.
  """
  use Phoenix.Presence,
    otp_app: :emisar_web,
    pubsub_server: Emisar.PubSub.Server

  def track_runner(pid, account_id, runner_id) do
    track(pid, "presence:account:#{account_id}", runner_id, %{
      online_at: System.system_time(:second),
      node: node()
    })
  end

  def list_for_account(account_id) do
    list("presence:account:#{account_id}")
  end

  def runner_online?(account_id, runner_id) do
    case Map.get(list_for_account(account_id), runner_id) do
      %{metas: [_ | _]} -> true
      _ -> false
    end
  end
end
