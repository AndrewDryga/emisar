defmodule FixtureApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_app,
      version: "0.1.0",
      elixir: "~> 1.14",
      deps: [],
      releases: [fixture_app: [include_erts: true]]
    ]
  end

  def application do
    [mod: {FixtureApp.Application, []}, extra_applications: [:logger]]
  end
end
