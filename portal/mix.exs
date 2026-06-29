defmodule Emisar.Umbrella.MixProject do
  use Mix.Project

  # Single source of the product version: portal/VERSION. The /release skill
  # bumps that one file; the umbrella, both apps, the OTP release, and the
  # marketing footer (Application.spec(:emisar_web, :vsn)) all read it.
  @version "VERSION" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      # Phoenix 1.8 code reloader coordinates recompiles through a Mix
      # compilation listener. `mix phx.server` runs from the umbrella
      # root, so the listener is registered here (not in a child app).
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases(),
      releases: [
        emisar: [
          version: @version,
          applications: [
            emisar: :permanent,
            emisar_web: :permanent
          ],
          steps: [:assemble, :tar]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, ">= 0.0.0"},
      # Security gate (run in CI). Sobelow = static analysis for the
      # Phoenix surface; mix_audit = CVE/advisory scan of the lockfile.
      # dev/test only + runtime: false — never compiled into the release.
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["cmd mix setup"],
      "ecto.setup": ["do --app emisar ecto.setup"],
      "ecto.reset": ["do --app emisar ecto.reset"],
      "ecto.migrate": ["do --app emisar ecto.migrate"],
      "ecto.rollback": ["do --app emisar ecto.rollback"],
      "ecto.seed": ["do --app emisar ecto.seed"],
      "assets.deploy": ["do --app emisar_web assets.deploy"],
      test: ["cmd mix test"]
    ]
  end
end
