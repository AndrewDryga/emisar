import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
#
# Coop project policy exports direct service values in a box. Older Coop
# versions may only inject the service URL, so retain that compatibility path
# before falling back to the conventional host port.
db_port =
  cond do
    port = System.get_env("PGPORT") -> String.to_integer(port)
    url = System.get_env("COOP_SERVICE_DB_URL") -> URI.parse(url).port
    true -> 5432
  end

config :emisar, Emisar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("PGHOST", "localhost"),
  port: db_port,
  database: "emisar_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Every process in a test shares its owner's ONE sandbox connection, so a test
  # that deliberately races N callers — proving concurrent identical attempts
  # still create exactly one row — queues all N transactions on that connection
  # by design. DBConnection's load-shedding heuristic is built for a real pool
  # under pressure, and it reads that queue as an outage: past `queue_target` for
  # a whole `queue_interval` it starts dropping the tail with "connection not
  # available", failing the run on a slow machine rather than on a defect. The
  # queueing is the test's premise and cannot be removed without removing the
  # concurrency, so give the heuristic a ceiling no legitimate test reaches.
  queue_target: 5_000,
  queue_interval: 10_000

# The advertised origin pins port 80 explicitly — without it Phoenix would
# infer the URL port from the (unused, server: false) listen port 4002 and
# drift from the domain's `:public_url`.
public_url = [scheme: "http", host: "localhost", port: 80]

config :emisar, :public_url, public_url

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :emisar_web, EmisarWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  url: public_url,
  secret_key_base: "S1d0sqYUPUO4VjfuqukIgBitA+mmPo4Zn2s8xR+oKZsTF9fxI7oahrFmmEqecrKU",
  server: false

# Enables the endpoint sandbox plugs (`Phoenix.Ecto.SQL.Sandbox` + `EmisarWeb.Sandbox`)
# so a browser session can share the test's DB connection and `Emisar.Config`
# overrides via the `user-agent` metadata. Compile-gated in the endpoint.
config :emisar_web, sql_sandbox: true

# Print only warnings and errors during test
config :logger, level: :warning

# Background jobs disabled in tests; job modules are executed directly so DB
# work stays inside the caller's sandbox checkout.
config :emisar, Emisar.Accounts.Jobs.MonthlyReports, enabled: false
config :emisar, Emisar.Approvals.Jobs.ExpireOverdueRequests, enabled: false
config :emisar, Emisar.ApiKeys.Jobs.DeviceGrantCleanup, enabled: false
config :emisar, Emisar.Audit.Jobs.Retention, enabled: false
config :emisar, Emisar.Catalog.Jobs.PackVersionRetention, enabled: false
config :emisar, Emisar.Runners.Jobs.InactiveRunnerRetention, enabled: false
config :emisar, Emisar.Runs.Jobs.FleetObservability, enabled: false
config :emisar, Emisar.Billing.Jobs.SyncPaddleCustomers, enabled: false
config :emisar, Emisar.Billing.Jobs.SyncRunnerQuantities, enabled: false
config :emisar, Emisar.Billing.Jobs.SyncSubscriptions, enabled: false
config :emisar, Emisar.OAuth.Jobs.Cleanup, enabled: false
config :emisar, Emisar.MCPOperations.Jobs.ReplayRetention, enabled: false
config :emisar, Emisar.Runs.Jobs.DispatchTimeout, enabled: false
config :emisar, Emisar.Runs.Jobs.EventRetention, enabled: false
config :emisar, Emisar.Runs.Jobs.ActionRunRetention, enabled: false
config :emisar, Emisar.Runbooks.Jobs.AdvanceExecutions, enabled: false
config :emisar, Emisar.SSO.Jobs.AuthorizationReconcile, enabled: false

# A fixed version-compatibility policy so classification is deterministic:
# < 0.0.1 is unsupported, [0.0.1, 0.1.0) is outdated, >= 0.1.0 is supported.
# The bounds sit below the "0.1.0" runner/key fixture default so a stock
# fixture reads :supported (no stray chips, no enforced drop); tests opt into
# staleness with an explicit low version. Enforcement stays off here; the
# enforce-path tests (their own async:false files) flip the flag themselves.
config :emisar, Emisar.Compat,
  runner_minimum: ">= 0.0.1",
  runner_recommended: ">= 0.1.0",
  runner_current: "0.1.0",
  runner_enforce: false,
  mcp_minimum: ">= 0.0.1",
  mcp_recommended: ">= 0.1.0",
  mcp_current: "0.1.0",
  mcp_enforce: false

# Paddle is stubbed in tests so we never hit the network.
config :emisar, paddle_client: Emisar.Billing.PaddleClient.Stub

# Analytics off by default (so the suite stays free of it) and, when a
# test opts in (`mixpanel_enabled: true` + `analytics_test_pid: self()`),
# synchronous and routed to the stub — so the stub's `send/2` lands in
# the test process for `assert_receive`. Never touches the network.
config :emisar,
  mixpanel_client: Emisar.Analytics.MixpanelClient.Stub,
  mixpanel_enabled: false,
  analytics_async?: false

# In test we don't send emails
config :emisar, Emisar.Mailer, adapter: Emisar.MailerTestAdapter

# A fixed secret so the Postmark webhook controller test can authenticate.
config :emisar, postmark_webhook_secret: "pm_webhook_test"

# Run `Approvals.notify_approvers/3` synchronously in tests so its DB
# reads happen inside the test's sandbox checkout. With the async path
# (Task.start) the spawned process can outlive the test and trigger
# `owner #PID<...> exited` warnings during teardown.
config :emisar, notify_approvers_async?: false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Skip the Prometheus exporter in tests — the in-process Bandit port
# binds 9091 globally, which (a) collides with anything else trying
# to use it and (b) is dead weight for the suite.
config :emisar_web, enable_prometheus_exporter: false

# Skip the production telemetry poller in tests. Its periodic fleet-wide DB
# samplers run in the supervisor process, outside the async sandbox owner; the
# sampler functions are tested directly in Emisar.TelemetryTest.
config :emisar_web, enable_telemetry_poller: false

# Disable Sentry uploads in tests — no DSN means the client short-
# circuits before any HTTP call.
config :sentry, dsn: nil

# Rate limiting is disabled in tests so the fast suite doesn't trip the
# shared fixed-window counters; `Emisar.RateLimiter.check/3` is unit-tested
# directly instead (see rate_limiter_test.exs).
config :emisar, rate_limit_enabled: false

# Dev/test metadata documents are served from loopback, which the CIMD SSRF
# boundary refuses by default. Never set in production.
config :emisar, Emisar.OAuth.ClientMetadataDocument, allow_private_hosts: true
