# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :emisar,
  ecto_repos: [Emisar.Repo],
  paddle_client: Emisar.Billing.PaddleClient.Live,
  # Web-side handler `Emisar.Auth` calls when it needs to disconnect
  # active LiveView sockets (the broadcast struct itself lives in the
  # `phoenix` package, which emisar deliberately doesn't depend on).
  session_disconnect_handler: EmisarWeb.SessionDisconnector,
  # Supervised Task fan-out for cross-app background work (currently
  # approval email blasts). Lives in the web app's supervision tree so
  # SIGTERM gracefully drains in-flight tasks instead of dropping them
  # on the floor. Resolved by name at call-time; nil-safe.
  task_supervisor: EmisarWeb.TaskSupervisor

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Local

# Background jobs — Oban runs delivery retries, audit retention, billing sync.
config :emisar, Oban,
  repo: Emisar.Repo,
  plugins: [
    # Rescue jobs stuck in `executing` because a node was shut down mid-run
    # (e.g. a Fly deploy) back to `available`. Safe because our workers are
    # idempotent (IL-13); rescue_after defaults to 60 minutes.
    Oban.Plugins.Lifeline,
    # Prune completed/cancelled/discarded jobs older than 7 days so the
    # oban_jobs table stays bounded.
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # REINDEX CONCURRENTLY the oban_jobs indexes weekly to release the index
    # bloat VACUUM leaves behind on a high-churn, frequently-pruned table.
    {Oban.Plugins.Reindexer, schedule: "@weekly"},
    {Oban.Plugins.Cron,
     crontab: [
       {"@daily", Emisar.Workers.AuditRetention},
       # Staggered 15 min after AuditRetention so the two audit-queue
       # sweeps don't contend on the same midnight tick.
       {"15 0 * * *", Emisar.Workers.ActionRunEventRetention},
       {"*/5 * * * *", Emisar.Workers.ApprovalExpiry},
       # Prune expired OAuth authorization codes (single-use, 60s artifacts;
       # no forensic value once expired — tokens are kept, not swept here).
       {"@daily", Emisar.Workers.OAuthCleanup},
       # Every minute — picks up runs that have been pending/sent past
       # the 2-min grace window and forces them to a terminal state.
       {"* * * * *", Emisar.Workers.RunDispatchTimeout},
       {"0 * * * *", Emisar.Workers.BillingSync}
     ]}
  ],
  queues: [
    default: 10,
    deliveries: 20,
    billing: 5,
    audit: 5,
    mailers: 10
  ]

config :emisar_web,
  ecto_repos: [Emisar.Repo],
  generators: [context_app: :emisar, binary_id: true]

# Configures the endpoint
config :emisar_web, EmisarWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EmisarWeb.ErrorHTML, json: EmisarWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Emisar.PubSub.Server,
  live_view: [signing_salt: "WbYZF/5Q"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  emisar_web: [
    args:
      ~w(js/app.js js/marketing.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/emisar_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  emisar_web: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/emisar_web/assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :account_id,
    :user_id,
    :membership_id,
    :runner_id,
    :run_id,
    :req_id,
    :policy_decision,
    :paddle_subscription_id,
    :reason,
    :error,
    :count
  ]

# Status-page URL surfaced as a "Status" link in the marketing footer
# and the in-app sidebar. Default is the Better Stack hosted page
# (configure the actual subdomain once Better Stack onboarding is done).
# Overridable at boot via `STATUS_PAGE_URL` in runtime.exs.
config :emisar_web, status_page_url: "https://status.emisar.dev"

# Sentry — DSN is opt-in via `SENTRY_DSN` env var (wired in
# `runtime.exs`). Leaving it unset disables uploads — the client
# short-circuits before any HTTP call. The default is intentionally
# nil so a fork / self-host can't accidentally ship errors to the
# upstream project's Sentry bucket.
config :sentry,
  dsn: nil,
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  tags: %{app: "emisar"}

# Mailer "From" address. Self-hosters override these with
# `MAILER_FROM_EMAIL` / `MAILER_FROM_NAME` in `runtime.exs`. Defaults
# match the emisar-hosted brand.
config :emisar,
  mailer_from_email: "no-reply@emisar.dev",
  mailer_from_name: "emisar"

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Filter secrets from Phoenix's request-param logging line. The default
# only filters "password" — everything else (bearer tokens, OTPs,
# magic-link tokens, raw API keys, auth keys, paddle webhook bodies)
# would otherwise land in Logger / Sentry / log shipper as plaintext.
# `:discard` drops the value entirely; `:keep` would mask but keep
# matches in the line — discard is the safer default for credentials.
config :phoenix,
       :filter_parameters,
       {:discard, ~w(password current_password password_confirmation token raw_token
           secret api_key auth_key bearer authorization mfa otp recovery_code
           webhook_signature)}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
