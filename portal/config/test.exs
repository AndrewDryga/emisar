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

# Stripe is stubbed in tests so we never hit the network.
config :emisar, stripe_client: Emisar.Billing.StripeClient.Stub

# In test we don't send emails
config :emisar, Emisar.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
