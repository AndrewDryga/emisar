defmodule Emisar.Release do
  @moduledoc """
  Release-time tasks. Mix isn't available in a release, so anything
  that needs to run inside the running release (migrations, seeds,
  rollback) lives here and gets invoked via `bin/emisar eval`.
  """

  @app :emisar

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(Emisar.Repo, fn _repo ->
      Code.eval_file(Application.app_dir(@app, "priv/repo/seeds.exs"))
    end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
