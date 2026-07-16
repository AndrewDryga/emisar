defmodule EmisarWeb.Plugs.MailboxPreviewCSP do
  @moduledoc """
  Allows Swoosh's development mailbox to embed its HTML message preview.

  The exception is limited to the forwarded `/dev/mailbox/:id/html` document.
  The mailbox routes are compiled out of production, and every other response
  retains the portal-wide `frame-ancestors 'none'` policy.
  """
  @behaviour Plug

  import Plug.Conn, only: [assign: 3]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: "/dev/mailbox/" <> rest} = conn, _opts) do
    if String.ends_with?(rest, "/html") do
      assign(conn, :csp_frame_ancestors, ["'self'"])
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
