import Config

# ./run supplies the same workspace-specific loopback URL on the host and in
# a Coop box. Keep the conventional localhost fallback for direct Mix usage.
repo_config =
  case System.get_env("DATABASE_URL") do
    nil ->
      [
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        database: "emisar_dev"
      ]

    url ->
      [url: url]
  end

config :emisar,
       Emisar.Repo,
       repo_config ++
         [
           stacktrace: true,
           show_sensitive_data_on_connection_error: true,
           pool_size: 10
         ]

dev_url = URI.parse(System.get_env("EMISAR_DEV_URL", "http://localhost:4000"))
public_url = [scheme: dev_url.scheme, host: dev_url.host, port: dev_url.port]
listen_port = String.to_integer(System.get_env("EMISAR_LISTEN_PORT", "4000"))

listen_ip =
  case System.get_env("EMISAR_LISTEN_IP", "127.0.0.1") do
    "0.0.0.0" -> {0, 0, 0, 0}
    "127.0.0.1" -> {127, 0, 0, 1}
    # Any other value is a typo; say so instead of a MatchError at config load.
    other -> raise "EMISAR_LISTEN_IP must be 127.0.0.1 or 0.0.0.0, got #{inspect(other)}"
  end

if ca_bundle = System.get_env("EMISAR_DEV_CA_BUNDLE") do
  config :public_key, cacerts_path: String.to_charlist(ca_bundle)
end

config :emisar, :public_url, public_url

# For development, we disable any cache and enable debugging and code
# reloading. The watchers bundle the .js and .css sources.
config :emisar_web, EmisarWeb.Endpoint,
  http: [ip: listen_ip, port: listen_port],
  url: public_url,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "pRrbdx2knkooMmO8d3Jji3NnltaIc8hddsuqzNdDJQ9mvAhF810Ec4DPPKx8LEfu",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:emisar_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:emisar_web, ~w(--watch)]}
  ]

# Watch static and templates for browser reloading.
config :emisar_web, EmisarWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/emisar_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :emisar_web, dev_routes: true

# Dev serves assets undigested at a fixed URL, so revalidate on every load
# instead of the prod-style immutable freeze — otherwise an edited JS/CSS stays
# cached (frozen casts, missing icons) until a hard refresh. See endpoint.ex.
config :emisar_web, :assets_cache_control, "no-cache"

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include HEEx debug annotations as HTML comments in rendered markup
  debug_heex_annotations: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20
