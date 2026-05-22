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
  stripe_client: Emisar.Billing.StripeClient.Live

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

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
