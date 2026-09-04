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
    * frame-ancestors: 'none' (we never embed product pages in an iframe).

  Pages that need extra origins (the Paddle `/checkout` page) opt in by
  setting `conn.assigns[:csp_extra]` to a map of directive name → extra
  sources (`%{"script-src" => ["https://cdn.paddle.com"]}`). The extras
  MERGE into the base directive's source list — a second `script-src`
  directive would be ignored by browsers, so appending whole directives
  can only ever add new ones, never widen an existing one. A directive
  absent from the base (e.g. `frame-src`) is added.

  Endpoint-rendered errors never reach a router pipeline, so `call/2` never
  runs for them; `put_error_content_security_policy/2` is the endpoint-level
  entry point that gives those responses a static policy instead.
  """
  @behaviour Plug

  import Plug.Conn

  # No page opt-in can reach an error the router never routed, so the fallback
  # is the fixed minimum rather than the per-request policy.
  @error_policy "default-src 'self'; object-src 'none'; frame-ancestors 'none'"

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

  @doc """
  Endpoint function plug: gives a response the router never routed — an
  unmatched path, or a failure in an endpoint plug — the static error policy.
  It lands at send time, so a pipeline that did run keeps its own policy.
  """
  def put_error_content_security_policy(conn, _opts),
    do: register_before_send(conn, &put_error_policy/1)

  defp put_error_policy(%{status: status} = conn)
       when is_integer(status) and status >= 400 and status < 600 do
    if get_resp_header(conn, "content-security-policy") == [] do
      put_resp_header(conn, "content-security-policy", @error_policy)
    else
      conn
    end
  end

  defp put_error_policy(conn), do: conn

  defp put_csp_header(conn, nonce) do
    extra = conn.assigns[:csp_extra] || %{}
    frame_ancestors = conn.assigns[:csp_frame_ancestors] || ["'none'"]

    policy =
      directives(nonce, frame_ancestors)
      |> merge_extra_sources(extra)
      |> Enum.map_join("; ", fn {name, sources} -> name <> " " <> Enum.join(sources, " ") end)

    put_resp_header(conn, "content-security-policy", policy)
  end

  # Per-request directives. `script-src` carries the nonce so the only
  # inline scripts we emit — the per-page JSON-LD in root.html.heex and the
  # checkout page's Paddle init — run without ever opening the door to
  # `'unsafe-inline'`.
  defp directives(nonce, frame_ancestors) do
    [
      {"default-src", ["'self'"]},
      {"script-src", ["'self'", "'nonce-#{nonce}'"]},
      {"style-src", ["'self'", "'unsafe-inline'"]},
      {"img-src", ["'self'", "data:", "https:"]},
      {"font-src", ["'self'"]},
      {"connect-src", ["'self'"]},
      {"frame-ancestors", frame_ancestors},
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
