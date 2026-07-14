defmodule EmisarWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :emisar_web

  # Session cookie. Signed AND encrypted so the session token inside is
  # opaque to client-side JS and to anyone who only has the cookie
  # blob. The `secure` flag is forced on in prod via runtime.exs; here
  # it's off so dev http://localhost works.
  @session_options [
    store: :cookie,
    key: "_emisar_web_key",
    signing_salt: "58sTQmlr",
    encryption_salt: "vN82Tq4r",
    same_site: "Lax",
    http_only: true
  ]

  # `:peer_data` + `:user_agent` + `:x_headers` are surfaced so the LiveView
  # boundary (`EmisarWeb.RequestContext.from_socket/1`) can build the caller's
  # `%RequestContext{}` at mount and stamp it onto the subject. `:x_headers`
  # carries `x-forwarded-for` so the real client IP (not the GCP proxy peer) reaches
  # audit + analytics. Without these, mounts behind LV land with no
  # conn-equivalent metadata.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :user_agent, :x_headers, session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # The release runs phx.digest, so serve the pregzipped assets — and match
  # root-level files by STEM (only_matching): the digested request is
  # /favicon-<hash>.ico, which the literal `only: ~w(favicon.ico …)` list
  # rejected, 404ing every favicon/manifest in prod while dev (undigested
  # paths) looked fine. `EmisarWeb.static_paths/0` keeps the literal names
  # for ~p verified-route checking.
  plug Plug.Static,
    at: "/",
    from: :emisar_web,
    gzip: true,
    only: ~w(assets fonts images robots.txt .well-known),
    only_matching: ~w(favicon apple-touch-icon android-chrome site)

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :emisar_web
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # We use a path-bounded body reader where a security boundary needs exact
  # bytes: Paddle verifies its HMAC, while MCP rejects ambiguous JSON and checks
  # signed argument slices. `Plug.Parsers` otherwise consumes those bytes before
  # the controller can inspect them.
  # A thin wrapper over Plug.Parsers: a malformed body on /api/mcp/rpc returns the
  # JSON-RPC -32700 parse-error envelope instead of the generic 400 (every other
  # path is unchanged). Same options Plug.Parsers takes.
  plug EmisarWeb.Plugs.JSONRPCParseError,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {EmisarWeb.CachedBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug EmisarWeb.Router
end
