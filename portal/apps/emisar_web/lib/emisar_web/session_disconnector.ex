defmodule EmisarWeb.SessionDisconnector do
  @moduledoc """
  Web-side broadcaster called by `Emisar.Auth` (and `Emisar.Admin`, for staff
  sessions) when ended or changed sessions need to land on every open
  LiveView socket (a sign-out or revoked session; a Member's suspension,
  removal or role change; an MFA reset; an admin's "end all sessions").

  Lives in `emisar_web` because the broadcast message has to be a
  `%Phoenix.Socket.Broadcast{}` struct (that's what `Phoenix.LiveView.Channel`
  pattern-matches on for the "disconnect" event), and that struct is in
  the `phoenix` package — which the data-layer `emisar` app deliberately
  doesn't pull in.

  Wired via
  `config :emisar, :session_disconnect_handler, {:emisar_web, EmisarWeb.SessionDisconnector}`.
  """

  @doc """
  Broadcast a `disconnect` event to each `live_socket_id` topic so any
  attached LiveView tears down server-side. Best-effort + idempotent;
  Phoenix.LiveView ignores topics with no subscribers.
  """
  def disconnect_live_sessions(topics) when is_list(topics) do
    Enum.each(topics, &EmisarWeb.Endpoint.broadcast(&1, "disconnect", %{}))
  end
end
