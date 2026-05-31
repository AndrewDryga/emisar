import Config

# config/runtime.exs runs every boot, including releases. Put env-driven
# secrets here so the container can be rebuilt without leaking values.

if config_env() == :prod do
  # Logger metadata captured per call (runner_id, request_id,
  # policy_decision, etc.) is emitted alongside each line in logfmt-ish
  # key=value form — queryable in fly's log drain without grep parsing.
  # Switch to a JSON formatter (logger_json) when log shipping needs it.
  config :logger,
    level: :info,
    handle_otp_reports: true

  config :logger, :default_formatter,
    format: "$dateT$time level=$level $message $metadata\n",
    metadata: [
      :request_id,
      :runner_id,
      :run_id,
      :policy_decision,
      :user_id,
      :account_id
    ]

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is missing (example: ecto://USER:PASS@HOST/DATABASE)"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :emisar, Emisar.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6,
    ssl: System.get_env("DATABASE_SSL") in ~w(true 1)

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing (generate with: mix phx.gen.secret)"

  host = System.get_env("PHX_HOST") || "app.emisar.dev"

  # FORCE_SSL=false disables the HTTP→HTTPS redirect AND the
  # secure-cookie pin. Required for local docker-compose dev (plain
  # HTTP), and for production deployments behind a TLS-terminating
  # proxy that already handles the redirect itself. Defaults to true.
  force_ssl_enabled? = System.get_env("FORCE_SSL", "true") in ~w(true 1)
  url_scheme = if force_ssl_enabled?, do: "https", else: "http"
  url_port = if force_ssl_enabled?, do: 443, else: String.to_integer(System.get_env("PORT") || "4000")

  endpoint_opts = [
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4000")
    ],
    secret_key_base: secret_key_base,
    server: true
  ]

  endpoint_opts =
    if force_ssl_enabled?,
      do: Keyword.put(endpoint_opts, :force_ssl, hsts: true, host: nil),
      else: endpoint_opts

  config :emisar_web, EmisarWeb.Endpoint, endpoint_opts

  # Force `secure: true` on the remember-me cookie + tighten the session
  # cookie. Combined with force_ssl above, browsers will never send the
  # cookie over plain HTTP. Disabled when FORCE_SSL=false so local dev
  # over http://localhost can still complete sign-in.
  config :emisar_web, force_secure_cookies: force_ssl_enabled?

  config :emisar, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  if url = System.get_env("STATUS_PAGE_URL") do
    config :emisar_web, status_page_url: url
  end

  # -- Mailer (Postmark by default; Mailgun and SMTP available as
  # fallbacks if you swap providers later) --------------------------
  cond do
    System.get_env("POSTMARK_API_TOKEN") ->
      config :emisar, Emisar.Mailer,
        adapter: Swoosh.Adapters.Postmark,
        api_key: System.fetch_env!("POSTMARK_API_TOKEN")

      config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Emisar.Finch

    System.get_env("MAILGUN_API_KEY") ->
      config :emisar, Emisar.Mailer,
        adapter: Swoosh.Adapters.Mailgun,
        api_key: System.fetch_env!("MAILGUN_API_KEY"),
        domain: System.fetch_env!("MAILGUN_DOMAIN")

      config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Emisar.Finch

    System.get_env("SMTP_HOST") ->
      config :emisar, Emisar.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: System.fetch_env!("SMTP_HOST"),
        port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        tls: :always

    true ->
      config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Local
  end

  # -- Sentry --------------------------------------------------------
  # Default DSN comes from config.exs so it works in every env. Allow
  # SENTRY_DSN to override at boot for staging / sandbox projects.
  if dsn = System.get_env("SENTRY_DSN") do
    config :sentry,
      dsn: dsn,
      environment_name: System.get_env("SENTRY_ENVIRONMENT") || "production",
      release: System.get_env("RELEASE_VSN")
  end

  # -- Paddle --------------------------------------------------------
  if System.get_env("PADDLE_API_KEY") do
    config :emisar,
      paddle_client: Emisar.Billing.PaddleClient.Live,
      paddle_api_key: System.fetch_env!("PADDLE_API_KEY"),
      paddle_webhook_secret: System.fetch_env!("PADDLE_WEBHOOK_SECRET")

    if id = System.get_env("PADDLE_PRICE_ID_TEAM"),
      do: config(:emisar, {:paddle_price_id, "team"}, id)
  else
    config :emisar, paddle_client: Emisar.Billing.PaddleClient.Stub
  end
end

# Always use the stub Paddle client in dev / test unless a real key was set.
if config_env() in [:dev, :test] do
  if System.get_env("PADDLE_API_KEY") do
    config :emisar,
      paddle_client: Emisar.Billing.PaddleClient.Live,
      paddle_api_key: System.fetch_env!("PADDLE_API_KEY"),
      paddle_webhook_secret: System.get_env("PADDLE_WEBHOOK_SECRET") || "pdl_ntfset_test"
  else
    config :emisar, paddle_client: Emisar.Billing.PaddleClient.Stub
  end
end
