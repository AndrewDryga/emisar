import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :emisar, Emisar.Repo,
  username: "postgres",
  password: "postgres",
  # PGHOST covers the coop box (sibling postgres at service name "db"); host dev and CI leave it unset.
  hostname: System.get_env("PGHOST", "localhost"),
  database: "emisar_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :emisar_web, EmisarWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "S1d0sqYUPUO4VjfuqukIgBitA+mmPo4Zn2s8xR+oKZsTF9fxI7oahrFmmEqecrKU",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Background jobs disabled in tests; job modules are executed directly so DB
# work stays inside the caller's sandbox checkout.
config :emisar, Emisar.Accounts.Jobs.MonthlyReports, enabled: false
config :emisar, Emisar.Approvals.Jobs.ExpireOverdueRequests, enabled: false
config :emisar, Emisar.Audit.Jobs.Retention, enabled: false
config :emisar, Emisar.Billing.Jobs.SyncPaddleCustomers, enabled: false
config :emisar, Emisar.Billing.Jobs.SyncSubscriptions, enabled: false
config :emisar, Emisar.OAuth.Jobs.Cleanup, enabled: false
config :emisar, Emisar.Runs.Jobs.DispatchTimeout, enabled: false
config :emisar, Emisar.Runs.Jobs.EventRetention, enabled: false

# A fixed version-compatibility policy so classification is deterministic:
# < 0.0.1 is unsupported, [0.0.1, 0.1.0) is outdated, >= 0.1.0 is supported.
# The bounds sit below the "0.1.0" runner/key fixture default so a stock
# fixture reads :supported (no stray chips, no enforced drop); tests opt into
# staleness with an explicit low version. Enforcement stays off here; the
# enforce-path tests (their own async:false files) flip the flag themselves.
config :emisar, Emisar.Compat,
  runner_minimum: ">= 0.0.1",
  runner_recommended: ">= 0.1.0",
  runner_enforce: false,
  mcp_minimum: ">= 0.0.1",
  mcp_recommended: ">= 0.1.0",
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
config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Test

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
# shared fixed-window counters; `EmisarWeb.RateLimiter.check/3` is unit-tested
# directly instead (see rate_limiter_test.exs).
config :emisar_web, rate_limit_enabled: false
