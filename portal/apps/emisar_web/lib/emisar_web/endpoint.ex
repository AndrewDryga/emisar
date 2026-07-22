defmodule EmisarWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :emisar_web

  # Endpoint-rendered errors bypass router pipelines, so register this before
  # any request plug that could fail before the router runs.
  plug EmisarWeb.Plugs.ErrorContentSecurityPolicy

  # Session cookie. Signed AND encrypted so the session token inside is
  # opaque to client-side JS and to anyone who only has the cookie
  # blob. The request-time session plug adds the `secure` flag from the
  # runtime config; the LiveView connect_info path below only reads this base.
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
  # Content-hashed build output (`app-<digest>.css` / `.js`) — the digest in the
  # filename IS the cache key, so freeze it: cache a year and never revalidate.
  # Scoped to /assets so the non-fingerprinted files below (images, fonts,
  # favicons, robots/LLM indexes) keep the default revalidating cache — those
  # reuse their URL when their bytes change, so they must not be frozen.
  plug Plug.Static,
    at: "/assets",
    from: {:emisar_web, "priv/static/assets"},
    gzip: true,
    cache_control_for_etags: "public, max-age=31536000, immutable"

  plug Plug.Static,
    at: "/",
    from: :emisar_web,
    gzip: true,
    only: ~w(fonts images robots.txt llms.txt .well-known),
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

  # Acceptance/browser tests carry the Ecto-sandbox owner in the `user-agent`:
  # the first plug shares the test's DB connection, the second plants that owner
  # as `:last_caller_pid` so `Emisar.Config` overrides reach the request process.
  # Compile-gated to the test env — never present in dev or prod.
  if Application.compile_env(:emisar_web, :sql_sandbox, false) do
    plug Phoenix.Ecto.SQL.Sandbox
    plug EmisarWeb.Sandbox
  end

  # The GCP load balancer probes /readyz and the auto-healer probes /healthz on
  # every instance every few seconds; logging each request's start/stop at :info
  # buried the app log in health-check noise. The :log hook skips just those two
  # paths (endpoint_log_level/1 below) — every other request still logs at :info,
  # so we keep the operational/audit signal a lower global level would discard.
  plug Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {__MODULE__, :endpoint_log_level, []}

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
  plug :session
  plug EmisarWeb.Router

  # Plug.Telemetry :log hook (see the plug above). false skips request logging
  # for the health probes; every other path logs at :info.
  def endpoint_log_level(%Plug.Conn{path_info: ["healthz"]}), do: false
  def endpoint_log_level(%Plug.Conn{path_info: ["readyz"]}), do: false
  def endpoint_log_level(%Plug.Conn{}), do: :info

  defp session(conn, _opts) do
    session_config = Plug.Session.init(session_options())
    Plug.Session.call(conn, session_config)
  end

  defp session_options do
    secure? = Emisar.Config.get_env(:emisar_web, :force_secure_cookies, false)
    Keyword.put(@session_options, :secure, secure?)
  end
end
