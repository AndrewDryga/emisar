defmodule Emisar.Release do
  @moduledoc """
  Release-time tasks. Mix isn't available in a release, so anything
  that needs to run inside the release lives here. Migrations and seeds
  are invoked via `bin/emisar eval`. There is no rollback task on
  purpose: applied migrations are frozen and an application rollback
  redeploys a prior image without reversing DB changes
  (.agent/kb/runbooks/deployment.md).

  The staff commands (`create_staff/1`, `reset_staff/1`, `remove_staff/1`,
  `list_staff/0`) run on the live node, from `./run ops portal remsh`, and
  are the only way a staff login is created or changed
  (.agent/kb/runbooks/staff-access.md).
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
        with_migration_lock(repo, fn ->
          Emisar.Release.Migrations.run(repo, Ecto.Migrator.migrations_path(repo))
        end)
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
  INVALID index and an unwritten version row behind. One advisory lock over the
  whole run makes the loser wait, including while recovering interrupted DDL.
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

  # The authenticator app lists staff entries under this issuer, apart from the
  # `emisar` entries of workspace sign-ins.
  @staff_issuer "emisar-admin"

  @doc """
  Creates the staff login for `email` and prints its authenticator key, once.
  The only way a staff login comes to exist. Run it on the live node:
  `./run ops portal remsh`, then `Emisar.Release.create_staff("you@example.com")`.
  """
  def create_staff(email) when is_binary(email) do
    case Emisar.Admin.create_staff(email) do
      {:ok, staff, secret} ->
        IO.puts("Created the staff login for #{staff.email}.")
        print_staff_key(staff, secret)

      {:error, %Ecto.Changeset{} = changeset} ->
        IO.puts("Not created: #{changeset_errors(changeset)}")
        :error
    end
  end

  @doc """
  Gives the staff login for `email` a new authenticator key and prints it,
  once. Signs the login out everywhere and unlocks it after wrong codes. Use it
  for a lost device or a lockout.
  """
  def reset_staff(email) when is_binary(email) do
    case Emisar.Admin.reset_staff(email) do
      {:ok, staff, secret} ->
        IO.puts("Reset the staff login for #{staff.email}. Its sessions have ended.")
        print_staff_key(staff, secret)

      {:error, :not_found} ->
        IO.puts("No staff login uses #{email}.")
        :error
    end
  end

  @doc "Deletes the staff login for `email` and ends its sessions."
  def remove_staff(email) when is_binary(email) do
    case Emisar.Admin.remove_staff(email) do
      :ok ->
        IO.puts("Removed the staff login for #{email}. Its sessions have ended.")
        :ok

      {:error, :not_found} ->
        IO.puts("No staff login uses #{email}.")
        :error
    end
  end

  @doc "Prints every staff login and whether wrong codes have locked it."
  def list_staff do
    case Emisar.Admin.list_staff() do
      [] ->
        IO.puts("No staff logins.")

      staff ->
        Enum.each(staff, fn login ->
          locked = if Emisar.Admin.staff_locked?(login), do: " (locked: reset it)", else: ""
          IO.puts("#{login.email}#{locked}")
        end)
    end

    :ok
  end

  defp print_staff_key(staff, secret) do
    key = Base.encode32(secret, padding: false)
    label = URI.encode(staff.email, &URI.char_unreserved?/1)
    uri = "otpauth://totp/#{@staff_issuer}:#{label}?secret=#{key}&issuer=#{@staff_issuer}"

    uri |> EQRCode.encode() |> EQRCode.render()

    IO.puts("""

    Scan the code above with your authenticator app, or enter this key by hand.
    It is shown only now; a lost key needs Emisar.Release.reset_staff/1.

      Key: #{key}

    Sign in at #{Emisar.PublicUrl.url("/admin/sign_in")}
    """)

    :ok
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
