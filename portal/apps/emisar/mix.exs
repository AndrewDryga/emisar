defmodule Emisar.MixProject do
  use Mix.Project

  def project do
    [
      app: :emisar,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Emisar.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix glue
      {:dns_cluster, "~> 0.1.1"},
      {:phoenix_pubsub, "~> 2.1"},

      # Persistence
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},
      {:ecto_psql_extras, "~> 0.7"},

      # Background jobs (delivery retries, audit ingestion, etc.)
      {:oban, "~> 2.18"},

      # Auth — password hashing and TOTP for MFA
      {:bcrypt_elixir, "~> 3.0"},
      {:nimble_totp, "~> 1.0"},

      # Outbound email + HTTP
      {:swoosh, "~> 1.16"},
      {:finch, "~> 0.18"},
      {:gen_smtp, "~> 1.2"},

      # Misc primitives
      {:jason, "~> 1.4"},
      {:ymlr, "~> 5.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "ecto.seed"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "ecto.seed": ["run #{__DIR__}/priv/repo/seeds.exs"],
      "test.ci": ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
