import Config

# config/runtime.exs runs every boot, including releases. Put env-driven
# secrets here so the container can be rebuilt without leaking values.
#
# Required prod env vars (boot raises if missing):
#   DATABASE_URL           — ecto://user:pass@host/db (direct/local database path)
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
#   DATABASE_SSL_CACERTFILE — PEM file to verify the server cert against
#                            (Cloud SQL / private-CA Postgres); implies TLS.
#                            For plain TLS with the system trust store, put
#                            `?ssl=true` in DATABASE_URL — Ecto parses it and it
#                            overrides the default here.
#   DATABASE_HOST          — host for passwordless proxy connections
#   DATABASE_USER          — user for passwordless proxy connections
#   DATABASE_NAME          — database for passwordless proxy connections
#   DATABASE_PORT          — proxy port (default 5432)
#   DATABASE_ROLE          — PostgreSQL role assumed at connection startup
#   POSTMARK_API_TOKEN     — mailer adapter (Postmark); unset logs mail instead
#   MAILER_FROM_EMAIL      — override the "From" address (default no-reply@emisar.dev)
#   MAILER_FROM_NAME       — override the "From" display name (default emisar)
#   SENTRY_DSN             — enables error uploads when set
#   SENTRY_ENVIRONMENT     — Sentry env tag (default "production")
#   STATUS_PAGE_URL        — status-page URL surfaced in nav + footer
#   RELEASE_VSN            — used in Sentry's `release` field
#   MIXPANEL_TOKEN         — enables server-side product analytics (off if unset)
#   MIXPANEL_API_HOST      — Mixpanel host (default api.mixpanel.com; EU: api-eu.mixpanel.com)
#   MIXPANEL_GROUPS        — "1"/"true" to also write Mixpanel Group profiles (paid add-on)
#   POSTMARK_WEBHOOK_SECRET — shared secret Postmark's bounce/complaint webhook
#                            must present; unset rejects every delivery
#   EMISAR_CLUSTER_PROJECT — GCP project for GCE peer discovery; ALSO what makes
#                            clustering happen at all, and the Cloud Logging
#                            project id. Set by the instance template.
#   EMISAR_CLUSTER_VALUE   — the GCE tag peers are discovered by
#   EMISAR_PACK_CATALOG_URL — published catalog to refresh auto-trust from;
#                            empty pins the bundled snapshot
#   EMISAR_SSO_ALLOWED_IDP_HOSTS — extra IdP hosts the SSRF guard permits
#   EMISAR_DISABLE_BILLING — "1" to run without Paddle (CI smoke, self-host)
#   EMISAR_DEV_ROUTES      — build-time; exposes dev-only routes. Never prod.
#   X_ADS_CONVERSIONS_JSON — enables server-side X signup conversion reporting;
#                            JSON with consumer_key, consumer_secret, access_token,
#                            access_token_secret, pixel_id, and event_id

# Blank counts as absent for EVERY optional variable below. Terraform templates
# and the docker-compose e2e stack pass optionals through as "${VAR:-}", and ""
# is truthy in Elixir — so a blank must select the default branch, never a live
# client holding an empty credential or a URL built from an empty host.
env = fn name ->
  case System.get_env(name) do
    "" -> nil
    value -> value
  end
end

if config_env() == :prod do
  # Google Cloud's structured payload recognizes severity, request context,
  # source locations, traces, and Error Reporting events. The project ID is
  # injected by the GCE instance template as EMISAR_CLUSTER_PROJECT.
  # EMISAR_CLUSTER_PROJECT only. The three GOOGLE_*/GCLOUD_* spellings that used
  # to precede it are auto-injected by Cloud Run and App Engine, which this is
  # not — it runs on GCE instances whose template sets EMISAR_CLUSTER_PROJECT
  # (infra/runtime/portal/start.sh). Nothing ever set them, so they were three
  # ways to be surprised by an inherited value rather than three ways to
  # configure it.
  gcp_project_id = env.("EMISAR_CLUSTER_PROJECT")

  # Keep application metadata queryable, but never serialize the request and
  # socket structs. GoogleCloud handles :crash_reason separately so caught
  # exceptions are sent in the shape Google Cloud Error Reporting recognizes.
  config :logger,
    level: :info,
    handle_otp_reports: true

  config :logger, :default_handler,
    formatter:
      LoggerJSON.Formatters.GoogleCloud.new(
        project_id: gcp_project_id,
        service_context: %{
          service: "emisar",
          version: env.("RELEASE_VSN") || "unknown"
        },
        reported_levels: [:emergency, :alert, :critical, :error],
        metadata: {:all_except, [:conn, :socket, :crash_reason]},
        redactors: [
          LoggerJSON.Redactors.RedactKeys.new(
            Application.fetch_env!(:emisar, :log_redaction_keys)
          )
        ]
      )

  # Cloud SQL (and any private-CA Postgres) signs its server cert with an
  # instance-specific CA that no public trust store carries, so `ssl: true`'s
  # public-CA verification can never pass (unknown_ca). With a CA file we pin
  # verification to that CA instead: validating the chain against the
  # per-instance CA IS the server authentication. Hostname matching is
  # skipped deliberately — the cert names "<project>:<instance>", never the
  # private IP we dial, so it could never match and adds nothing on top of
  # the pinned chain.
  # No DATABASE_SSL boolean: Ecto already parses `?ssl=true` out of DATABASE_URL
  # and merges it OVER this config, so the env var was a second, untested
  # spelling of something the URL says in the standard way. What the URL cannot
  # express is a private CA, which is the only reason this stays.
  database_ssl =
    case env.("DATABASE_SSL_CACERTFILE") do
      nil ->
        false

      cacertfile ->
        [
          verify: :verify_peer,
          cacertfile: cacertfile,
          customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
        ]
    end

  database_connection =
    case env.("DATABASE_URL") do
      url when is_binary(url) ->
        [url: url, ssl: database_ssl]

      nil ->
        [
          hostname: env.("DATABASE_HOST") || raise("DATABASE_HOST is missing"),
          username: env.("DATABASE_USER") || raise("DATABASE_USER is missing"),
          database: env.("DATABASE_NAME") || raise("DATABASE_NAME is missing"),
          port: String.to_integer(env.("DATABASE_PORT") || "5432"),
          ssl: false
        ]
    end

  database_parameters =
    case env.("DATABASE_ROLE") do
      role when is_binary(role) -> [role: role]
      nil -> []
    end

  repo_config =
    database_connection ++
      [
        pool_size: String.to_integer(env.("POOL_SIZE") || "10"),
        parameters: database_parameters
      ]

  config :emisar, Emisar.Repo, repo_config

  secret_key_base =
    env.("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing (generate with: mix phx.gen.secret)"

  # Salt for the cookieless daily anonymous-visitor hash — reuse the app secret
  # so every node agrees and an attacker can't recompute a day's ids.
  config :emisar, :analytics_salt, secret_key_base
  config :emisar, :email_link_secret, secret_key_base
  config :emisar, :mcp_telemetry_salt, secret_key_base

  host = env.("PHX_HOST") || "emisar.dev"

  # FORCE_SSL marks this deployment as HTTPS-fronted: it drives the public
  # URL scheme/port and the secure-cookie pin below. The actual HTTP→HTTPS
  # redirect + HSTS is the compile-time `force_ssl` in prod.exs (Phoenix 1.8
  # requires it at compile time), NOT this knob. docker-compose sets it
  # false for plain-HTTP localhost. Defaults to true.
  https_fronted? = (env.("FORCE_SSL") || "true") in ~w(true 1)
  url_scheme = if https_fronted?, do: "https", else: "http"

  # HTTPS-fronted → 443. Otherwise URL_PORT (if set) overrides the listen PORT
  # for URL generation — needed when a published host port differs from the
  # container's listen port (docker-compose maps host 4010 → container 4000, so
  # redirect_uris / email links must advertise 4010 while we listen on 4000).
  url_port =
    if https_fronted? do
      443
    else
      String.to_integer(env.("URL_PORT") || env.("PORT") || "4000")
    end

  # One shared origin binding for the endpoint's `url:` and the domain's
  # `:public_url` (Emisar.PublicUrl) — the two must never diverge.
  public_url = [host: host, port: url_port, scheme: url_scheme]

  config :emisar, :public_url, public_url

  endpoint_opts = [
    url: public_url,
    http: [
      ip: {0, 0, 0, 0},
      port: String.to_integer(env.("PORT") || "4000")
    ],
    secret_key_base: secret_key_base,
    server: true
  ]

  config :emisar_web, EmisarWeb.Endpoint, endpoint_opts

  # Browser cookies read this shared runtime knob for their `secure` attribute:
  # the session plug and `RecentAccounts.opts/0` use it. Combined with the
  # compile-time `force_ssl` (prod.exs), browsers never send them over plain
  # HTTP. Disabled when FORCE_SSL=false so local dev over http://localhost can
  # still complete sign-in.
  config :emisar_web, force_secure_cookies: https_fronted?

  # BEAM clustering on GCP MIGs. When EMISAR_CLUSTER_PROJECT is set (the instance
  # template sets it), libcluster's GCE strategy lists the project's RUNNING portal
  # instances via the Compute API and connects them as `emisar@<internal-ip>`
  # (rel/env.sh.eex names the node). Unset in local and single-node releases, the
  # topology stays empty and the cluster supervisor is inert.
  cluster_topologies =
    case env.("EMISAR_CLUSTER_PROJECT") do
      project when is_binary(project) ->
        [
          emisar: [
            strategy: Emisar.Cluster.GCE,
            config: [
              project_id: project,
              cluster_value: env.("EMISAR_CLUSTER_VALUE") || "emisar"
            ]
          ]
        ]

      nil ->
        []
    end

  config :emisar, :cluster_topologies, cluster_topologies

  if url = env.("STATUS_PAGE_URL") do
    config :emisar_web, status_page_url: url
  end

  # The one variable that does NOT go through `env` above: blank is a third,
  # deliberate value here (pin the bundled snapshot), not "unset".
  pack_catalog_url =
    case System.get_env("EMISAR_PACK_CATALOG_URL") do
      nil -> "https://registry.emisar.dev/v1/catalog.json"
      "" -> nil
      url -> url
    end

  # The published pack catalog the registry refreshes from (the bundled
  # catalog.json is the boot fallback). Points at the immutable v1 pointer on
  # the vendor-neutral serving domain — the same base packctl bakes into
  # tarball_urls, so the tarball-base pin (Cache.pin_tarballs) agrees; override
  # for a mirror or a staging bucket (a self-host base still pins to itself).
  # An explicitly empty value disables remote refresh and serves the bundled
  # catalog, which keeps image smoke tests and offline self-hosts deterministic.
  config :emisar, Emisar.Catalog.PublishedRegistry, catalog_url: pack_catalog_url

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

    postmark_api_token = env.("POSTMARK_API_TOKEN") ->
      config :emisar, Emisar.Mailer,
        adapter: Swoosh.Adapters.Postmark,
        api_key: postmark_api_token

      config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Emisar.Finch

    true ->
      # No mail provider configured — log every send instead of crashing
      # at delivery. `Swoosh.Adapters.Local` needs a Memory storage
      # GenServer that only exists in dev; the Logger adapter is process-
      # free, ideal for staging/disabled-mail prod builds.
      config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Logger
  end

  # Postmark bounce/complaint webhook auth (optional — unset or blank disables
  # the endpoint with a 503; the mailer still works, suppression just won't fill).
  config :emisar, postmark_webhook_secret: env.("POSTMARK_WEBHOOK_SECRET")

  # -- Sentry --------------------------------------------------------
  # Sentry DSN is opt-in via env. Leaving it unset disables uploads
  # (the client short-circuits before any HTTP call). config.exs
  # ships a nil default so a fork never accidentally posts errors to
  # the upstream project's bucket.
  if dsn = env.("SENTRY_DSN") do
    config :sentry,
      dsn: dsn,
      environment_name: env.("SENTRY_ENVIRONMENT") || "production",
      release: env.("RELEASE_VSN")
  end

  # -- Mailer From -----------------------------------------------------
  # `MAILER_FROM_EMAIL` / `MAILER_FROM_NAME` let self-hosters use their
  # own domain without forking. Skipping either falls back to the
  # config.exs default.
  if email = env.("MAILER_FROM_EMAIL"),
    do: config(:emisar, :mailer_from_email, email)

  if name = env.("MAILER_FROM_NAME"),
    do: config(:emisar, :mailer_from_name, name)

  # -- Paddle --------------------------------------------------------
  # Production is loud about Paddle config so we never silently fall
  # through to the stub client (billing would appear to work but no
  # revenue events would land). To run a prod build with billing
  # disabled (e.g. an internal staging tier), set
  # `EMISAR_DISABLE_BILLING=1` — that's the only way to skip Paddle.
  cond do
    paddle_api_key = env.("PADDLE_API_KEY") ->
      config :emisar,
        paddle_client: Emisar.Billing.PaddleClient.Live,
        paddle_api_key: paddle_api_key,
        paddle_webhook_secret:
          env.("PADDLE_WEBHOOK_SECRET") ||
            raise("PADDLE_WEBHOOK_SECRET is required whenever PADDLE_API_KEY is set."),
        paddle_client_token:
          env.("PADDLE_CLIENT_TOKEN") ||
            raise("""
            PADDLE_CLIENT_TOKEN is missing. The /checkout page needs a Paddle
            client-side token to open Paddle Checkout — create one in the Paddle
            dashboard under Developer Tools → Authentication and set it alongside
            PADDLE_API_KEY (or set EMISAR_DISABLE_BILLING=1 to ship the stub).
            """)

    env.("EMISAR_DISABLE_BILLING") in ~w(true 1) ->
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
  # (the `Emisar.Analytics` no-op path) — no third-party script ships.
  if token = env.("MIXPANEL_TOKEN") do
    config :emisar,
      mixpanel_client: Emisar.Analytics.MixpanelClient.Live,
      mixpanel_token: token,
      mixpanel_enabled: true

    # EU data residency: set https://api-eu.mixpanel.com.
    if host = env.("MIXPANEL_API_HOST"),
      do: config(:emisar, :mixpanel_api_host, host)

    # Mixpanel Group Analytics is a paid add-on — opt in explicitly.
    if env.("MIXPANEL_GROUPS") in ~w(1 true),
      do: config(:emisar, :mixpanel_groups_enabled, true)
  end

  # -- X Ads conversions ----------------------------------------------
  # DISCLOSURE GATE: setting this starts sending a click id, a timestamp, and an
  # opaque dedup hash to X Corp — a processor named on NONE of /privacy, /trust,
  # or /dpa, which between them carry the one processor list we publish. Add X to
  # all three (and the marketing test that pins them) in the same change that
  # populates this variable, or the pages become false the moment it is set.
  if encoded = env.("X_ADS_CONVERSIONS_JSON") do
    credentials = Jason.decode!(encoded)

    config :emisar,
      x_ads_conversions: %{
        consumer_key: Map.fetch!(credentials, "consumer_key"),
        consumer_secret: Map.fetch!(credentials, "consumer_secret"),
        access_token: Map.fetch!(credentials, "access_token"),
        access_token_secret: Map.fetch!(credentials, "access_token_secret"),
        pixel_id: Map.fetch!(credentials, "pixel_id"),
        event_id: Map.fetch!(credentials, "event_id")
      }
  end
end

# Exact `host:port` endpoints which the OIDC guard may exempt from its private-
# address policy. This exists only for development and test builds, whose local
# Keycloak cannot have a public address. The build-time dev-routes flag separates
# the packaged local stack from a production image even if the same runtime env
# variables are injected into both.
allowed_idp_hosts_env = env.("EMISAR_SSO_ALLOWED_IDP_HOSTS")

development_or_test_build? =
  config_env() in [:dev, :test] or EmisarWeb.Router.dev_routes?()

if is_binary(allowed_idp_hosts_env) and not development_or_test_build? do
  IO.warn(
    "EMISAR_SSO_ALLOWED_IDP_HOSTS is ignored outside development and test builds",
    []
  )
end

sso_allowed_idp_hosts =
  if development_or_test_build? do
    (allowed_idp_hosts_env || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  else
    []
  end

config :emisar, :sso_allowed_idp_hosts, sso_allowed_idp_hosts

# Always use the stub Paddle client in dev / test unless a real key was set
# (the sandbox e2e harness exports one via `./run e2e billing`).
if config_env() in [:dev, :test] do
  if dev_paddle_api_key = env.("PADDLE_API_KEY") do
    config :emisar,
      paddle_client: Emisar.Billing.PaddleClient.Live,
      paddle_api_key: dev_paddle_api_key,
      paddle_webhook_secret: env.("PADDLE_WEBHOOK_SECRET") || "pdl_ntfset_test",
      paddle_client_token: env.("PADDLE_CLIENT_TOKEN")
  else
    config :emisar, paddle_client: Emisar.Billing.PaddleClient.Stub
  end
end

# Version enforcement is the deliberate operator flip `compatibility.md`
# describes: the thresholds stay in config.exs, and a peer below the minimum is
# only warned about until the matching switch is set on the deployment.
config :emisar, Emisar.Compat,
  runner_enforce: env.("EMISAR_ENFORCE_RUNNER_VERSION") == "true",
  mcp_enforce: env.("EMISAR_ENFORCE_MCP_VERSION") == "true"
