defmodule Emisar.CatalogManagementConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Catalog, Fixtures, Repo, Runners, Users}

  @moduletag timeout: 60_000

  test "a pack decision does not wait for an unrelated runner update" do
    unboxed_catalog(fn %{account: account, admin: admin, version: version} ->
      unrelated = Fixtures.Runners.create_runner(account_id: account.id, group: "production")
      parent = self()

      updater =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Runners.fetch_and_lock_active_runner(unrelated.id, account.id)
            send(parent, :unrelated_runner_locked)

            receive do
              :commit -> :committed
            end
          end)
        end)

      try do
        assert_receive :unrelated_runner_locked, 5_000
        assert {:ok, revoked} = Catalog.revoke_pack_version_trust(version.id, admin)
        assert revoked.trust_state == :rejected
      after
        send(updater.pid, :commit)
        stop_tasks([updater])
      end
    end)
  end

  test "the locked membership rejects a concurrent demotion before version mutation" do
    unboxed_catalog(fn %{membership: membership, admin: admin, version: version} ->
      parent = self()

      demoter =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Fixtures.Memberships.force_role(membership, "viewer")
            send(parent, {:demotion, backend_pid()})

            receive do
              :commit -> :committed
            end
          end)
        end)

      assert_receive {:demotion, blocker}, 5_000

      manager =
        unboxed_task(fn ->
          send(parent, {:manager, backend_pid()})
          Catalog.revoke_pack_version_trust(version.id, admin)
        end)

      try do
        assert_receive {:manager, waiting}, 5_000
        await_blocked_by(waiting, blocker)
        send(demoter.pid, :commit)
        assert Task.await(demoter, 30_000) == {:ok, :committed}
        assert Task.await(manager, 30_000) == {:error, :unauthorized}
        assert Repo.reload!(version).trust_state == :trusted
      after
        send(demoter.pid, :commit)
        stop_tasks([demoter, manager])
      end
    end)
  end

  defp unboxed_catalog(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(row in Accounts.Account, where: row.id == ^account.id))
          Repo.delete_all(from(row in Users.User, where: row.id == ^user.id))
        end)
      end)

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "admin"
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "staging")

      version =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: "custom",
          version: "1.0"
        )

      {:ok, _runner} = Runners.apply_state(runner, %{"packs" => advertisement(version)})
      {:ok, access} = Accounts.RunnerAccess.new(:restricted, ["staging"], [])
      membership = Fixtures.Memberships.force_runner_access(membership, access)
      admin = Fixtures.Subjects.membership_subject(membership)

      try do
        fun.(%{
          account: account,
          user: user,
          membership: membership,
          runner: runner,
          admin: admin,
          version: version
        })
      after
        Repo.delete_all(from(row in Accounts.Account, where: row.id == ^account.id))
        Repo.delete_all(from(row in Users.User, where: row.id == ^user.id))
      end
    end)
  end

  defp advertisement(version),
    do: %{version.pack_id => %{"version" => version.version, "hash" => version.hash}}
end
