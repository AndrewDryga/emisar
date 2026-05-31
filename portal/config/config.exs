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
  paddle_client: Emisar.Billing.PaddleClient.Live

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
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"@daily", Emisar.Workers.AuditRetention},
       {"*/5 * * * *", Emisar.Workers.RunnerHealthSweep},
       {"*/5 * * * *", Emisar.Workers.ApprovalExpiry},
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
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
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
  metadata: [:request_id]

# Status-page URL surfaced as a "Status" link in the marketing footer
# and the in-app sidebar. Default is the Better Stack hosted page
# (configure the actual subdomain once Better Stack onboarding is done).
# Overridable at boot via `STATUS_PAGE_URL` in runtime.exs.
config :emisar_web, status_page_url: "https://status.emisar.dev"

# Sentry — DSN baked in (it's a public-ish key with an event-rate-limit
# quota, not a secret). Tagging each event with `config_env/0` means
# dev errors don't pollute the production project's dashboard.
# `runtime.exs` lets `SENTRY_DSN` override at boot for staging.
config :sentry,
  dsn:
    "https://f3095640e074c473f52dbcc92f79201c@o4511481560498176.ingest.us.sentry.io/4511481561481216",
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  tags: %{app: "emisar"}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
