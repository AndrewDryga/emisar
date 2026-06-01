defmodule EmisarWeb.SessionDisconnector do
  @moduledoc """
  Web-side broadcaster called by `Emisar.Auth` when a "kill this user's
  live sessions" event needs to land on every open LiveView socket
  (suspend membership, force password reset, password change "log out
  other devices", admin "end all sessions").

  Lives in `emisar_web` because the broadcast message has to be a
  `%Phoenix.Socket.Broadcast{}` struct (that's what `Phoenix.LiveView.Channel`
  pattern-matches on for the "disconnect" event), and that struct is in
  the `phoenix` package — which the data-layer `emisar` app deliberately
  doesn't pull in.

  Wired via `config :emisar, :session_disconnect_handler, EmisarWeb.SessionDisconnector`.
  """

  @doc """
  Broadcast a `disconnect` event to each `live_socket_id` topic so any
  attached LiveView tears down server-side. Best-effort + idempotent;
  Phoenix.LiveView ignores topics with no subscribers.
  """
  def disconnect_live_sessions(topics) when is_list(topics) do
    Enum.each(topics, fn topic ->
      EmisarWeb.Endpoint.broadcast(topic, "disconnect", %{})
    end)
  end
end
