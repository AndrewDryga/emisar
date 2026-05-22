defmodule Emisar.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [
        emisar: [
          version: "0.1.0",
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
    [{:phoenix_live_view, ">= 0.0.0"}]
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
