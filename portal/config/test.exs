import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :emisar, Emisar.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
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

# Use a tiny bcrypt cost factor in tests — defaults to 12 which adds
# ~250ms per password hash and makes the suite glacial.
config :bcrypt_elixir, :log_rounds, 4

# Background jobs disabled in tests; assert on side-effects inline. The
# `queues: false, plugins: false` is required for sandboxed tests — without it
# Oban tries to verify migrations during Application startup, holding
# real (non-sandbox) connections and exhausting the pool.
config :emisar, Oban,
  testing: :inline,
  queues: false,
  plugins: false

# Paddle is stubbed in tests so we never hit the network.
config :emisar, paddle_client: Emisar.Billing.PaddleClient.Stub

# In test we don't send emails
config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Test

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

# Skip the Prometheus exporter in tests — the in-process Cowboy port
# binds 9091 globally, which (a) collides with anything else trying
# to use it and (b) is dead weight for the suite.
config :emisar_web, enable_prometheus_exporter: false

# Disable Sentry uploads in tests — no DSN means the client short-
# circuits before any HTTP call.
config :sentry, dsn: nil

# Rate limiting is disabled in tests so the fast suite doesn't trip the
# shared fixed-window counters; `EmisarWeb.RateLimiter.check/3` is unit-tested
# directly instead (see rate_limiter_test.exs).
config :emisar_web, rate_limit_enabled: false
