defmodule EmisarWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :emisar_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EmisarWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      # Phoenix.LiveViewTest's HTML parser. Floki was the previous one
      # and is no longer used (LV 1.0+ uses LazyHTML exclusively).
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.7"},
      {:esbuild, "~> 0.10.0", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4.1", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_metrics_prometheus, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      # Optional: error reporting via Sentry. Compiled out when
      # SENTRY_DSN isn't set (init/0 short-circuits on no-DSN).
      {:sentry, "~> 13.1"},
      {:gettext, "~> 1.0"},
      {:emisar, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.11"},
      {:websock_adapter, "~> 0.5"},
      # Used only at compile time by EmisarWeb.PacksRegistry to load the
      # pack catalog from YAML files. The parsed data is baked into the
      # module, so the lib is not needed at runtime.
      {:yaml_elixir, "~> 2.12", runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind emisar_web", "esbuild emisar_web"],
      "assets.deploy": [
        "tailwind emisar_web --minify",
        "esbuild emisar_web --minify",
        "phx.digest"
      ]
    ]
  end
end
