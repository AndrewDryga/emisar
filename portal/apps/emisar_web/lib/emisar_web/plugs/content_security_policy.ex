defmodule EmisarWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sends a hardened `Content-Security-Policy` header on every HTML
  response. Layered on top of Phoenix's `put_secure_browser_headers`
  (which only sets the bare minimum X-Frame-Options / X-XSS-Protection
  / referrer-policy defaults).

  Defaults are deliberately strict — anything we don't actively need is
  blocked. Today we load:

    * scripts: same-origin (our `app.js`) plus a per-request `'nonce-…'`
      stamped onto the only inline `<script>` we emit (the per-page
      JSON-LD block in `root.html.heex`). `'unsafe-inline'` and
      `'unsafe-eval'` are never allowed — the nonce is assigned to
      `conn.assigns.csp_nonce` for the layout to read.
    * styles: same-origin and `'unsafe-inline'` — Phoenix LiveView's
      colocated `<style>` blocks rely on inline styles. (See
      hexdocs.pm/phoenix_live_view/colocated_hook for the relevant
      note.)
    * fonts: same-origin only — Inter is self-hosted under
      `priv/static/fonts` (no third-party font CDN).
    * connect-src: same-origin + `wss:` (LiveView websocket).
    * frame-ancestors: 'none' (we never embed in an iframe).

  Pages that need to allow extra origins (e.g. Paddle checkout if it
  ever embeds JS) can opt in by setting `conn.assigns[:csp_extra]` —
  the plug picks that up and merges in the extra directives.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    extra = conn.assigns[:csp_extra] || []

    policy = Enum.join(directives(nonce) ++ extra, "; ")

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy)
    # Process-isolate the page from any window it opens / that opened it, so a
    # cross-origin opener can't reach into this document (and the page becomes
    # cross-origin-isolated capable). We never rely on window.opener.
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
  end

  # Per-request directives. `script-src` carries the nonce so the only
  # inline script we emit — the per-page JSON-LD in root.html.heex — runs
  # without ever opening the door to `'unsafe-inline'`.
  defp directives(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "font-src 'self'",
      "connect-src 'self' wss: ws:",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "object-src 'none'"
    ]
  end
end
