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
  task_supervisor: EmisarWeb.TaskSupervisor,
  # Product analytics (Mixpanel). Off by default and routed to the stub
  # client; prod with a `MIXPANEL_TOKEN` flips `mixpanel_enabled` and
  # swaps in the Live client (runtime.exs). Server-side ingestion only —
  # no third-party script ships.
  mixpanel_client: Emisar.Analytics.MixpanelClient.Stub,
  mixpanel_enabled: false,
  mixpanel_api_host: "https://api.mixpanel.com",
  mixpanel_groups_enabled: false,
  # Secret salt for the cookieless daily anonymous-visitor hash. Prod overrides
  # it with SECRET_KEY_BASE (runtime.exs); this non-secret default is dev/test.
  analytics_salt: "emisar-dev-analytics-salt",
  # HMAC key for privacy-safe MCP client/call correlation in logs. Production
  # derives it from SECRET_KEY_BASE; this non-secret value is for dev/test.
  mcp_telemetry_salt: "emisar-dev-mcp-telemetry-salt",
  # Signing secret for stateless emailed links (the monthly-report
  # unsubscribe token). Prod derives it from SECRET_KEY_BASE (runtime.exs);
  # this non-secret default is dev/test.
  email_link_secret: "emisar-dev-email-link-secret-value"

# Control-plane version-compatibility policy for runners and the
# emisar-mcp bridge (Emisar.Compat). These targets are the coordinated releases
# that implement this portal's wire contracts. Publish both artifacts before
# deploying a portal with newer targets. Enforcement remains warn-only until
# deliberately flipped on.
config :emisar, Emisar.Compat,
  runner_minimum: ">= 0.10.0",
  runner_recommended: ">= 0.10.0",
  runner_enforce: false,
  mcp_minimum: ">= 0.3.0",
  mcp_recommended: ">= 0.3.0",
  mcp_enforce: false

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Local

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
    :mcp_tool,
    :mcp_validation_stage,
    :mcp_validation_kind,
    :mcp_validation_issues,
    :mcp_call_fingerprint,
    :mcp_unknown_tool_shape,
    :mcp_schema_version,
    :mcp_client_lineage,
    :mcp_client_name,
    :mcp_client_version,
    :mcp_bridge_version,
    :policy_decision,
    :paddle_subscription_id,
    :reason,
    :error,
    :count,
    :job,
    :connected_runners,
    :pending_dispatch_depth
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
  before_send: {EmisarWeb.Application, :scrub_sentry_event},
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  tags: %{app: "emisar"}

# Mailer "From" address. Self-hosters override these with
# `MAILER_FROM_EMAIL` / `MAILER_FROM_NAME` in `runtime.exs`. Defaults
# match the emisar-hosted brand.
config :emisar,
  log_redaction_keys: ~w[password token secret authorization api_key key_hash token_hash],
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
