defmodule EmisarWeb.SessionDisconnector do
  @moduledoc """
  Web-side broadcaster called by `Emisar.Auth` (and `Emisar.Admin`, for staff
  sessions) when ended or changed sessions need to land on every open
  LiveView socket (a sign-out or revoked session; a Member's suspension,
  removal or role change; an MFA reset; an admin's "end all sessions").

  Workspace LiveViews subscribe to their session topic themselves and
  `EmisarWeb.UserAuth` answers the broadcast with a full-page redirect. Staff
  sessions carry a `live_socket_id`, so Phoenix closes their socket transport
  (`Phoenix.Socket`) on the same "disconnect" event.

  Lives in `emisar_web` because it broadcasts through `EmisarWeb.Endpoint`,
  which the data-layer `emisar` app does not reference directly.

  Wired via
  `config :emisar, :session_disconnect_handler, {:emisar_web, EmisarWeb.SessionDisconnector}`.
  """

  @doc """
  Broadcast a `disconnect` event to each session topic so any attached
  LiveView reloads or closes. Best-effort + idempotent; a topic with no
  subscribers drops the broadcast.
  """
  def disconnect_live_sessions(topics) when is_list(topics) do
    Enum.each(topics, &EmisarWeb.Endpoint.broadcast(&1, "disconnect", %{}))
  end
end
