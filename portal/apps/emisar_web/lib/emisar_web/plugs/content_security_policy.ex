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
    * connect-src: same-origin only. CSP's `'self'` matching includes the
      page's secure WebSocket origin, so LiveView does not need a broad
      `ws:` or `wss:` scheme allowance.
    * frame-ancestors: 'none' (we never embed in an iframe).

  Pages that need extra origins (the Paddle `/checkout` page) opt in by
  setting `conn.assigns[:csp_extra]` to a map of directive name → extra
  sources (`%{"script-src" => ["https://cdn.paddle.com"]}`). The extras
  MERGE into the base directive's source list — a second `script-src`
  directive would be ignored by browsers, so appending whole directives
  can only ever add new ones, never widen an existing one. A directive
  absent from the base (e.g. `frame-src`) is added.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    # The policy is computed at SEND time: this plug runs in the router
    # pipeline, long before a controller action could assign :csp_extra —
    # a call-time header would silently ignore every page opt-in.
    |> register_before_send(&put_csp_header(&1, nonce))
    # Process-isolate the page from any window it opens / that opened it, so a
    # cross-origin opener can't reach into this document (and the page becomes
    # cross-origin-isolated capable). We never rely on window.opener.
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
  end

  defp put_csp_header(conn, nonce) do
    extra = conn.assigns[:csp_extra] || %{}

    policy =
      directives(nonce)
      |> merge_extra_sources(extra)
      |> Enum.map_join("; ", fn {name, sources} -> name <> " " <> Enum.join(sources, " ") end)

    put_resp_header(conn, "content-security-policy", policy)
  end

  # Per-request directives. `script-src` carries the nonce so the only
  # inline scripts we emit — the per-page JSON-LD in root.html.heex and the
  # checkout page's Paddle init — run without ever opening the door to
  # `'unsafe-inline'`.
  defp directives(nonce) do
    [
      {"default-src", ["'self'"]},
      {"script-src", ["'self'", "'nonce-#{nonce}'"]},
      {"style-src", ["'self'", "'unsafe-inline'"]},
      {"img-src", ["'self'", "data:", "https:"]},
      {"font-src", ["'self'"]},
      {"connect-src", ["'self'"]},
      {"frame-ancestors", ["'none'"]},
      {"base-uri", ["'self'"]},
      {"form-action", ["'self'"]},
      {"object-src", ["'none'"]}
    ]
  end

  defp merge_extra_sources(base, extra) when extra == %{}, do: base

  defp merge_extra_sources(base, extra) do
    merged =
      Enum.map(base, fn {name, sources} -> {name, sources ++ Map.get(extra, name, [])} end)

    base_names = Enum.map(base, &elem(&1, 0))
    added = for {name, sources} <- Enum.sort(extra), name not in base_names, do: {name, sources}

    merged ++ added
  end
end
