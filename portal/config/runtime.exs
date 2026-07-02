import Config

# config/runtime.exs runs every boot, including releases. Put env-driven
# secrets here so the container can be rebuilt without leaking values.
#
# Required prod env vars (boot raises if missing):
#   DATABASE_URL           — ecto://user:pass@host/db
#   SECRET_KEY_BASE        — `mix phx.gen.secret`
#   PADDLE_API_KEY         — OR set EMISAR_DISABLE_BILLING=1 to use stub
#   PADDLE_WEBHOOK_SECRET  — required when PADDLE_API_KEY is set
#   PADDLE_CLIENT_TOKEN    — required when PADDLE_API_KEY is set; the client-side
#                            token Paddle.js initializes with on /checkout
#
# There is no price-id env var: checkout prices come from the live Paddle
# catalog, and plan identity + limits ride the webhook via the product's
# custom_data (plan, runners_limit, members_limit, audit_retention_days,
# features_sso_enabled?, features_scim_enabled?) — see Emisar.Billing.Entitlements.
#
# Optional prod env vars:
#   PHX_HOST               — public hostname (defaults to emisar.dev)
#   PORT                   — HTTP listen port (default 4000)
#   URL_PORT               — public URL port if it differs from PORT (e.g. a
#                            published host port); only applies when FORCE_SSL=false
#   FORCE_SSL              — "false" disables HTTPS redirect + secure cookies (default true)
#   POOL_SIZE              — Ecto pool size (default 10)
#   ECTO_IPV6              — "1" / "true" to dial Postgres over IPv6
#   DATABASE_SSL           — "1" / "true" to require TLS to Postgres
#   DNS_CLUSTER_QUERY      — libcluster DNS query for multi-node deploys
#   POSTMARK_API_TOKEN     — mailer adapter (Postmark)
#   MAILGUN_API_KEY        — mailer adapter (Mailgun); requires MAILGUN_DOMAIN
#   SMTP_HOST              — mailer adapter (SMTP); use SMTP_USERNAME/PASSWORD/PORT
#   MAILER_FROM_EMAIL      — override the "From" address (default no-reply@emisar.dev)
#   MAILER_FROM_NAME       — override the "From" display name (default emisar)
#   SENTRY_DSN             — enables error uploads when set
#   SENTRY_ENVIRONMENT     — Sentry env tag (default "production")
#   STATUS_PAGE_URL        — status-page URL surfaced in nav + footer
#   RELEASE_VSN            — used in Sentry's `release` field
#   MIXPANEL_TOKEN         — enables server-side product analytics (off if unset)
#   MIXPANEL_API_HOST      — Mixpanel host (default api.mixpanel.com; EU: api-eu.mixpanel.com)
#   MIXPANEL_GROUPS        — "1"/"true" to also write Mixpanel Group profiles (paid add-on)

if config_env() == :prod do
  # Structured JSON logs for the fly log drain: every Logger metadata
  # key ships as a queryable JSON field (no more curated key list to
  # drift), minus the huge per-request structs. Belt-and-suspenders
  # redaction of secret-shaped keys — the app never logs raw secrets,
  # but a future `inspect(changeset)` must not become an incident.
  config :logger,
    level: :info,
    handle_otp_reports: true

  config :logger, :default_handler,
    formatter:
      {LoggerJSON.Formatters.Basic,
       metadata: {:all_except, [:conn, :socket, :crash_reason]},
       redactors: [
         LoggerJSON.Redactors.RedactKeys.new(
           ~w[password token secret authorization api_key key_hash token_hash]
         )
       ]}

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

  # Salt for the cookieless daily anonymous-visitor hash — reuse the app secret
  # so every node agrees and an attacker can't recompute a day's ids.
  config :emisar, :analytics_salt, secret_key_base

  host = System.get_env("PHX_HOST") || "emisar.dev"

  # FORCE_SSL marks this deployment as HTTPS-fronted: it drives the public
  # URL scheme/port and the secure-cookie pin below. The actual HTTP→HTTPS
  # redirect + HSTS is the compile-time `force_ssl` in prod.exs (Phoenix 1.8
  # requires it at compile time), NOT this knob. docker-compose sets it
  # false for plain-HTTP localhost. Defaults to true.
  https_fronted? = System.get_env("FORCE_SSL", "true") in ~w(true 1)
  url_scheme = if https_fronted?, do: "https", else: "http"

  # HTTPS-fronted → 443. Otherwise URL_PORT (if set) overrides the listen PORT
  # for URL generation — needed when a published host port differs from the
  # container's listen port (docker-compose maps host 4010 → container 4000, so
  # redirect_uris / email links must advertise 4010 while we listen on 4000).
  url_port =
    if https_fronted? do
      443
    else
      String.to_integer(System.get_env("URL_PORT") || System.get_env("PORT") || "4000")
    end

  endpoint_opts = [
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4000"),
      # Bind the IPv6 wildcard as DUAL-STACK so the single socket also
      # accepts IPv4. Fly's kernel sets net.ipv6.bindv6only=1, and OTP's
      # socket backend honors it — without this override the listener is
      # IPv6-only, so fly-proxy (which reaches the app over IPv4) reports
      # "not listening on 0.0.0.0:4000" and the deploy fails its health
      # check. Restores the pre-OTP-28 dual-stack behavior.
      thousand_island_options: [transport_options: [ipv6_v6only: false]]
    ],
    secret_key_base: secret_key_base,
    server: true
  ]

  config :emisar_web, EmisarWeb.Endpoint, endpoint_opts

  # Force `secure: true` on the remember-me cookie + tighten the session
  # cookie. Combined with the compile-time `force_ssl` (prod.exs), browsers
  # never send the cookie over plain HTTP. Disabled when FORCE_SSL=false so
  # local dev over http://localhost can still complete sign-in.
  config :emisar_web, force_secure_cookies: https_fronted?

  config :emisar, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  if url = System.get_env("STATUS_PAGE_URL") do
    config :emisar_web, status_page_url: url
  end

  # -- Mailer (Postmark by default; Mailgun and SMTP available as
  # fallbacks if you swap providers later) --------------------------
  cond do
    System.get_env("EMISAR_DEV_ROUTES") == "1" ->
      # Dev stack (EMISAR_DEV_ROUTES=1): deliver into the in-memory mailbox the
      # /dev/mailbox preview reads, so passwordless magic-link sign-in works
      # locally with no mail provider. Re-enables the Swoosh memory storage that
      # prod.exs turns off. Never set on a real deploy.
      config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Local
      config :swoosh, local: true

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
      # No mail provider configured — log every send instead of crashing
      # at delivery. `Swoosh.Adapters.Local` needs a Memory storage
      # GenServer that only exists in dev; the Logger adapter is process-
      # free, ideal for staging/disabled-mail prod builds.
      config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Logger
  end

  # Postmark bounce/complaint webhook auth (optional — unset disables the
  # endpoint with a 503; the mailer still works, suppression just won't fill).
  config :emisar, postmark_webhook_secret: System.get_env("POSTMARK_WEBHOOK_SECRET")

  # -- Sentry --------------------------------------------------------
  # Sentry DSN is opt-in via env. Leaving it unset disables uploads
  # (the client short-circuits before any HTTP call). config.exs
  # ships a nil default so a fork never accidentally posts errors to
  # the upstream project's bucket.
  if dsn = System.get_env("SENTRY_DSN") do
    config :sentry,
      dsn: dsn,
      environment_name: System.get_env("SENTRY_ENVIRONMENT") || "production",
      release: System.get_env("RELEASE_VSN")
  end

  # -- Mailer From -----------------------------------------------------
  # `MAILER_FROM_EMAIL` / `MAILER_FROM_NAME` let self-hosters use their
  # own domain without forking. Skipping either falls back to the
  # config.exs default.
  if email = System.get_env("MAILER_FROM_EMAIL"),
    do: config(:emisar, :mailer_from_email, email)

  if name = System.get_env("MAILER_FROM_NAME"),
    do: config(:emisar, :mailer_from_name, name)

  # -- Paddle --------------------------------------------------------
  # Production is loud about Paddle config so we never silently fall
  # through to the stub client (billing would appear to work but no
  # revenue events would land). To run a prod build with billing
  # disabled (e.g. an internal staging tier), set
  # `EMISAR_DISABLE_BILLING=1` — that's the only way to skip Paddle.
  cond do
    System.get_env("PADDLE_API_KEY") ->
      config :emisar,
        paddle_client: Emisar.Billing.PaddleClient.Live,
        paddle_api_key: System.fetch_env!("PADDLE_API_KEY"),
        paddle_webhook_secret: System.fetch_env!("PADDLE_WEBHOOK_SECRET"),
        paddle_client_token:
          System.get_env("PADDLE_CLIENT_TOKEN") ||
            raise("""
            PADDLE_CLIENT_TOKEN is missing. The /checkout page needs a Paddle
            client-side token to open Paddle Checkout — create one in the Paddle
            dashboard under Developer Tools → Authentication and set it alongside
            PADDLE_API_KEY (or set EMISAR_DISABLE_BILLING=1 to ship the stub).
            """)

    System.get_env("EMISAR_DISABLE_BILLING") in ~w(true 1) ->
      config :emisar, paddle_client: Emisar.Billing.PaddleClient.Stub

    true ->
      raise """
      PADDLE_API_KEY is missing in production. Set it (along with
      PADDLE_WEBHOOK_SECRET and PADDLE_CLIENT_TOKEN) to enable billing,
      or set EMISAR_DISABLE_BILLING=1 to ship with the stub client.
      """
  end

  # -- Mixpanel (product analytics) ----------------------------------
  # Optional and quiet: no `MIXPANEL_TOKEN` means analytics stays off
  # (the `Emisar.Analytics` no-op path) — no third-party script ships
  # either way. See .agent/specs/mixpanel-analytics.md.
  if token = System.get_env("MIXPANEL_TOKEN") do
    config :emisar,
      mixpanel_client: Emisar.Analytics.MixpanelClient.Live,
      mixpanel_token: token,
      mixpanel_enabled: true

    # EU data residency: set https://api-eu.mixpanel.com.
    if host = System.get_env("MIXPANEL_API_HOST"),
      do: config(:emisar, :mixpanel_api_host, host)

    # Mixpanel Group Analytics is a paid add-on — opt in explicitly.
    if System.get_env("MIXPANEL_GROUPS") in ~w(1 true),
      do: config(:emisar, :mixpanel_groups_enabled, true)
  end
end

# Always use the stub Paddle client in dev / test unless a real key was set.
if config_env() in [:dev, :test] do
  if System.get_env("PADDLE_API_KEY") do
    config :emisar,
      paddle_client: Emisar.Billing.PaddleClient.Live,
      paddle_api_key: System.fetch_env!("PADDLE_API_KEY"),
      paddle_webhook_secret: System.get_env("PADDLE_WEBHOOK_SECRET") || "pdl_ntfset_test",
      paddle_client_token: System.get_env("PADDLE_CLIENT_TOKEN")
  else
    config :emisar, paddle_client: Emisar.Billing.PaddleClient.Stub
  end
end
