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

  # `:peer_data` + `:user_agent` are surfaced so the LiveView audit
  # `on_mount` hook (EmisarWeb.UserAuth.on_mount(:audit_meta, …)) can
  # stash IP + UA on the LV process. Without these, mounts behind LV
  # land with no conn-equivalent metadata.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :user_agent, session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.

  # Phoenix 1.8 reads the endpoint's `:force_ssl` at COMPILE time, so the
  # http→https redirect can no longer be toggled per-deploy through that
  # key (it tripped `validate_compile_env` on release boot). We apply
  # Plug.SSL ourselves from a runtime app-env flag instead: production
  # gets the redirect + HSTS, while FORCE_SSL=false deploys (docker-compose
  # dev, the CI smoke) serve plain HTTP. Runs first so nothing is served
  # before the redirect.
  plug :force_ssl_at_runtime

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

  # Runtime HTTPS enforcement (see the :force_ssl_at_runtime plug above).
  # `:force_ssl_opts` is set in runtime.exs from FORCE_SSL — nil means no
  # enforcement; otherwise it's the Plug.SSL opts (`hsts: true, host: nil`)
  # this app used pre-1.8.
  defp force_ssl_at_runtime(conn, _opts) do
    case Application.get_env(:emisar_web, :force_ssl_opts) do
      nil -> conn
      ssl_opts -> Plug.SSL.call(conn, Plug.SSL.init(ssl_opts))
    end
  end
end
