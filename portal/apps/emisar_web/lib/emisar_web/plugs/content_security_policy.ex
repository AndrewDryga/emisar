defmodule EmisarWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sends a hardened `Content-Security-Policy` header on every HTML
  response. Layered on top of Phoenix's `put_secure_browser_headers`
  (which only sets the bare minimum X-Frame-Options / X-XSS-Protection
  / referrer-policy defaults).

  Defaults are deliberately strict — anything we don't actively need is
  blocked. Today we load:

    * scripts: same-origin (our `app.js`). `'unsafe-inline'` and
      `'unsafe-eval'` are not allowed. Phoenix LiveView is fine without
      either.
    * styles: same-origin and `'unsafe-inline'` — Phoenix LiveView's
      colocated `<style>` blocks rely on inline styles. (See
      hexdocs.pm/phoenix_live_view/colocated_hook for the relevant
      note.)
    * fonts: same-origin + rsms.me (the Inter font CDN we already
      `<link>` from root.html.heex).
    * connect-src: same-origin + `wss:` (LiveView websocket).
    * frame-ancestors: 'none' (we never embed in an iframe).

  Pages that need to allow extra origins (e.g. Paddle checkout if it
  ever embeds JS) can opt in by setting `conn.assigns[:csp_extra]` —
  the plug picks that up and merges in the extra directives.
  """
  @behaviour Plug

  import Plug.Conn

  @default_directives [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline' https://rsms.me",
    "img-src 'self' data: https:",
    "font-src 'self' https://rsms.me",
    "connect-src 'self' wss: ws:",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'"
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    extra = conn.assigns[:csp_extra] || []

    policy =
      (@default_directives ++ extra)
      |> Enum.join("; ")

    put_resp_header(conn, "content-security-policy", policy)
  end
end
