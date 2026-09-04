defmodule Emisar.Release do
  @moduledoc """
  Release-time tasks. Mix isn't available in a release, so anything
  that needs to run inside the running release (migrations, seeds)
  lives here and gets invoked via `bin/emisar eval`. There is no
  rollback task on purpose: applied migrations are frozen and an
  application rollback redeploys a prior image without reversing DB
  changes (.github/DEPLOYMENT.md).
  """

  @app :emisar

  # The docker-compose stack builds the image with EMISAR_DEV_ROUTES=1 and a
  # production build never does — the same build marker the router uses to
  # decide whether /dev/* is compiled in at all.
  @dev_build? Application.compile_env(:emisar_web, :dev_routes, false)

  def migrate do
    load_app()

    for repo <- repos() do
      run = fn repo ->
        with_migration_lock(repo, fn -> Ecto.Migrator.run(repo, :up, all: true) end)
      end

      # The migrator needs two connections of its own; the lock holds a third
      # for the whole run.
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, run, pool_size: 3)
    end
  end

  @doc """
  Runs `fun` while this node holds the release's migration advisory lock.

  The managed instance group replaces VMs in parallel and every replacement runs
  `bin/migrate`, so two migrators can reach the same pending migration at once.
  Ecto takes its lock per migration and `@disable_migration_lock` turns that off
  for the concurrent-index migrations — precisely where a collision leaves an
  INVALID index and an unwritten version row behind, which no retry can clear.
  One advisory lock over the whole run makes the loser wait instead.
  """
  @spec with_migration_lock(Ecto.Repo.t(), (-> result)) :: result when result: term()
  def with_migration_lock(repo, fun) when is_function(fun, 0) do
    # Advisory locks share one namespace per database, so the key only has to be
    # stable — derive it from the task instead of picking a number nobody can check.
    key = :erlang.crc32("emisar.release.migrate")

    repo.checkout(
      fn ->
        # No timeout: the loser waits out the winner's index build, and a winner
        # that dies drops the lock with its session.
        Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_lock($1)", [key], timeout: :infinity)

        try do
          fun.()
        after
          Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [key])
        end
      end,
      timeout: :infinity
    )
  end

  def seed do
    unless @dev_build? do
      raise """
      Emisar.Release.seed/0 runs only in a development build. The demo seeds write
      demo accounts, users, runners and audit rows into whatever database this
      release points at, and take over connected runners' leases. Build the image
      with EMISAR_DEV_ROUTES=1 (the docker-compose stack does) to enable them.
      """
    end

    # Start the whole application so seeds can call business contexts
    # that need PubSub / supervised jobs / etc. — `with_repo` only starts the Repo,
    # which is enough for migrations but not for seeds that exercise
    # the dispatch path (`Runs.create_run` broadcasts on `Emisar.PubSub`).
    {:ok, _} = Application.ensure_all_started(@app)
    # Trusted, app-bundled seeds file evaluated at deploy time — not request input.
    # credo:disable-for-next-line Emisar.Checks.NoUnsafeDeserialization
    Code.eval_file(Application.app_dir(@app, "priv/repo/seeds.exs"))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
