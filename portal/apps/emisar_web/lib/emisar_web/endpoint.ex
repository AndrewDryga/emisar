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

  # `:peer_data` + `:user_agent` are surfaced so the LiveView boundary
  # (`EmisarWeb.RequestContext.from_socket/1`) can build the caller's
  # `%RequestContext{}` at mount and stamp it onto the subject. Without
  # these, mounts behind LV land with no conn-equivalent metadata.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :user_agent, session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :emisar_web,
    gzip: false,
    only: EmisarWeb.static_paths()

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

  # We use a custom body_reader so the Paddle webhook controller can
  # verify HMAC-SHA256 signatures against the exact bytes Paddle signed.
  # `Plug.Parsers` consumes the body before our controller runs, and
  # `read_body/2` only returns the unparsed bytes once.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {EmisarWeb.CachedBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug EmisarWeb.Router
end
