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
      # Phoenix glue. `phoenix` is here (not just in emisar_web) for
      # `Phoenix.Presence` — connection tracking is a domain concern
      # (workers + context reads need it), so the tracker lives in the
      # domain app. Same dep already resolved for emisar_web.
      {:dns_cluster, "~> 0.1.1"},
      {:phoenix, "~> 1.7.21"},
      {:phoenix_pubsub, "~> 2.1"},

      # Persistence
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},

      # Background jobs (delivery retries, audit ingestion, etc.)
      {:oban, "~> 2.18"},

      # Auth — password hashing and TOTP for MFA
      {:bcrypt_elixir, "~> 3.0"},
      {:nimble_totp, "~> 1.0"},
      # Pure-Elixir QR encoder — used to render scannable TOTP QRs
      # server-side as SVG so the profile MFA setup doesn't need a
      # third-party JS lib or an external image service.
      {:eqrcode, "~> 0.2"},

      # Outbound email + HTTP
      {:swoosh, "~> 1.16"},
      {:finch, "~> 0.18"},
      {:gen_smtp, "~> 1.2"},

      # Misc primitives
      {:jason, "~> 1.4"},
      # Compile-time pack baseline reads runner/examples/packs/*.yaml
      # to know each shipped pack's canonical hash. Auto-trust pinning
      # only — never started at runtime.
      {:yaml_elixir, "~> 2.11", runtime: false}
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
