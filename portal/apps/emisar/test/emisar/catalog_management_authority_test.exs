defmodule Emisar.CatalogManagementAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Audit, Catalog, Fixtures, Repo}
  alias Emisar.Catalog.RunnerAction

  @operations [
    :trust_pack_version,
    :reject_pack_version,
    :override_pack_retirement,
    :revoke_pack_version_trust,
    :delete_pack_version
  ]

  setup do
    account = Fixtures.Accounts.create_account()
    membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    admin = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: account.id, group: "staging")
    %{account: account, membership: membership, admin: admin, runner: runner}
  end

  describe "global pack-version management" do
    test "a scoped admin can manage every version whose complete target set is covered",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(membership, access)

      second =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "staging",
          connected?: false
        )

      Fixtures.Runners.disable_runner(second)

      for operation <- @operations do
        version = version_for(operation, account, runner)
        advertise(second, version, "other-hash")
        assert {:ok, changed} = apply(Catalog, operation, [version.id, admin])
        assert changed.id == version.id
      end
    end

    test "any-hash zero-action advertisers prevent partial decisions and leave all effects untouched",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      outside =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "production",
          connected?: false
        )

      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      Catalog.subscribe_account_packs(account.id)

      for operation <- @operations do
        version = version_for(operation, account, runner)
        advertise(outside, version, "not-the-pending-or-trusted-hash")
        actions = Repo.all(RunnerAction)
        events = Repo.all(Audit.Event)

        assert apply(Catalog, operation, [version.id, admin]) == {:error, :unauthorized}
        assert Repo.reload!(version) == version
        assert Repo.all(RunnerAction) == actions
        assert Repo.all(Audit.Event) == events
      end

      refute_receive {:pack_trust_changed, _account_id}
    end

    test "residual actions include tombstoned owners no longer advertising the version",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      outside = Fixtures.Runners.create_runner(account_id: account.id, group: "production")
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      Fixtures.Runners.mark_deleted(outside)

      for operation <- @operations do
        version = version_for(operation, account, runner)
        residual_action(outside, version)
        assert apply(Catalog, operation, [version.id, admin]) == {:error, :unauthorized}
        assert Repo.reload!(version) == version
      end

      {:ok, access} = RunnerAccess.new(:restricted, ["staging", "production"], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      version = Fixtures.Catalog.list_pack_versions(account.id) |> List.first()
      assert {:ok, _deleted} = Catalog.delete_pack_version(version.id, admin)
    end

    test "current permission attenuation, role and identity remain independent of runner scope",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      versions = Enum.map(@operations, &{&1, version_for(&1, account, runner)})
      attenuated = %{admin | permissions: MapSet.new()}

      for {operation, version} <- versions do
        assert apply(Catalog, operation, [version.id, attenuated]) == {:error, :unauthorized}
      end

      Fixtures.Memberships.force_role(membership, "operator")

      for {operation, version} <- versions do
        assert apply(Catalog, operation, [version.id, admin]) == {:error, :unauthorized}
      end

      membership |> Repo.reload!() |> Fixtures.Memberships.force_role("admin")
      Fixtures.Memberships.suspend_membership(membership)

      for {operation, version} <- versions do
        assert apply(Catalog, operation, [version.id, admin]) == {:error, :unauthorized}
        assert Repo.reload!(version) == version
      end
    end

    test "deleted users and a replacement membership cannot reuse a former manager subject",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      versions = Enum.map(@operations, &{&1, version_for(&1, account, runner)})
      membership |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

      replacement =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.actor.id,
          role: "admin"
        )

      for {operation, version} <- versions do
        assert apply(Catalog, operation, [version.id, admin]) == {:error, :unauthorized}
      end

      current = Fixtures.Subjects.membership_subject(replacement)
      Fixtures.Users.mark_user_as_deleted(admin.actor)

      for {operation, version} <- versions do
        assert apply(Catalog, operation, [version.id, current]) == {:error, :unauthorized}
      end
    end

    test "pack authority is checked before lifecycle while foreign and invalid ids stay missing",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      foreign = Fixtures.Accounts.create_account()
      {:ok, access} = RunnerAccess.new(:all, [], [], :restricted, ["different-pack"])
      Fixtures.Memberships.force_runner_access(membership, access)

      for operation <- @operations do
        version = version_for(operation, account, runner)

        foreign_version =
          Fixtures.Catalog.create_trusted_pack_version(
            account_id: foreign.id,
            pack_id: version.pack_id
          )

        assert apply(Catalog, operation, [version.id, admin]) == {:error, :unauthorized}
        assert apply(Catalog, operation, [foreign_version.id, admin]) == {:error, :not_found}
        assert apply(Catalog, operation, ["invalid", admin]) == {:error, :not_found}
      end
    end
  end

  describe "delete_pack/2" do
    test "whole-pack deletion retains pack-only authority but refreshes the actor and pack grant",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      version = version_for(:delete_pack_version, account, runner)

      {:ok, access} =
        RunnerAccess.new(:restricted, ["not-staging"], [], :restricted, [version.pack_id])

      Fixtures.Memberships.force_runner_access(membership, access)
      Fixtures.Memberships.force_role(membership, "operator")
      assert Catalog.delete_pack(version.pack_id, admin) == {:error, :unauthorized}
      membership |> Repo.reload!() |> Fixtures.Memberships.force_role("admin")
      assert {:ok, [deleted]} = Catalog.delete_pack(version.pack_id, admin)
      assert deleted.id == version.id
    end
  end

  describe "list_console_packs/2 management hints" do
    test "the complete target set, not the capped advertisement preview, determines management",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      version = version_for(:trust_pack_version, account, runner)
      outside = Fixtures.Runners.create_runner(account_id: account.id, group: "production")
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(membership, access)

      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      assert projection.can_manage?
      assert projection.version_facts[version.id].can_manage?
      advertise(outside, version, "different-hash")

      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      refute projection.version_facts[version.id].can_manage?
      Fixtures.Runners.mark_deleted(outside)
      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      assert projection.version_facts[version.id].can_manage?
      residual_action(outside, version)
      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      refute projection.version_facts[version.id].can_manage?
      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.all())
      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      assert projection.version_facts[version.id].can_manage?
      Fixtures.Memberships.force_role(membership, "viewer")
      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      refute projection.can_manage?
      refute projection.version_facts[version.id].can_manage?
    end

    test "500 management candidates use two slim denial queries, independent of fleet preview limits",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      outside = Fixtures.Runners.create_runner(account_id: account.id, group: "production")

      versions =
        for n <- 1..500 do
          Fixtures.Catalog.create_trusted_pack_version(
            account_id: account.id,
            pack_id: "batch-#{n}",
            version: "1.0"
          )
        end

      packs = Map.new(versions, &{&1.pack_id, %{"version" => &1.version, "hash" => &1.hash}})
      Fixtures.Runners.advertise_packs(runner, packs)
      Fixtures.Runners.advertise_packs(outside, packs)
      handler = make_ref()
      parent = self()

      :telemetry.attach(
        handler,
        [:emisar, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == parent, do: send(parent, {:query, metadata.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      queries = drain_queries()
      assert projection.version_count == 500
      assert Enum.all?(projection.version_facts, fn {_id, fact} -> not fact.can_manage? end)
      assert Enum.count(queries, &String.contains?(&1, "retention_pack_evidence")) == 1
      assert Enum.count(queries, &String.contains?(&1, "LEFT OUTER JOIN")) == 1
      assert Enum.count(queries, &String.contains?(&1, "catalog_runner_actions")) == 1
      assert length(queries) == 6
    end

    test "an ungranted advertiser beyond the 100-runner preview still disables management",
         %{account: account, membership: membership, admin: admin, runner: runner} do
      version = version_for(:trust_pack_version, account, runner)

      for n <- 1..99 do
        peer =
          Fixtures.Runners.create_runner(
            account_id: account.id,
            group: "staging",
            name: "peer-#{n}"
          )

        advertise(peer, version, version.pending_hash)
      end

      outside = Fixtures.Runners.create_runner(account_id: account.id, group: "zz-production")
      advertise(outside, version, "different-hash")
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      assert {:ok, projection} = Catalog.list_console_packs(%{}, admin)
      fact = projection.version_facts[version.id]
      assert fact.advertising.coverage == :partial
      assert length(fact.advertising.runners) == 100
      refute Enum.any?(fact.advertising.runners, &(&1.id == outside.id))
      refute fact.can_manage?
      assert Catalog.trust_pack_version(version.id, admin) == {:error, :unauthorized}
    end

    test "residual-owner query fails closed for an unresolved or foreign owner even with all runners",
         %{account: account} do
      foreign = Fixtures.Runners.create_runner()

      for runner_id <- [foreign.id, Ecto.UUID.generate()],
          access <- [RunnerAccess.all(), RunnerAccess.none()] do
        query =
          from(
            a in fragment(
              "(SELECT ?::uuid AS account_id, ?::uuid AS runner_id, 'custom'::text AS pack_id, '1.0'::text AS pack_version)",
              type(^account.id, :binary_id),
              type(^runner_id, :binary_id)
            ),
            as: :runner_actions
          )

        assert query
               |> RunnerAction.Query.outside_runner_access(access)
               |> RunnerAction.Query.distinct_pack_refs()
               |> Repo.all() == [{"custom", "1.0"}]
      end
    end
  end

  defp version_for(operation, account, runner) do
    attrs = %{account_id: account.id, pack_id: "authority-#{operation}", version: "1.0"}

    version =
      if operation in [:trust_pack_version, :reject_pack_version],
        do: Fixtures.Catalog.create_observed_pack_version(attrs),
        else: Fixtures.Catalog.create_trusted_pack_version(attrs)

    hash = version.pending_hash || version.hash
    advertise(runner, version, hash)
    residual_action(runner, version, hash)
    version
  end

  defp advertise(runner, version, hash) do
    runner = Repo.reload!(runner)

    packs =
      Map.put(runner.packs || %{}, version.pack_id, %{
        "version" => version.version,
        "hash" => hash
      })

    Fixtures.Runners.advertise_packs(runner, packs)
  end

  defp residual_action(runner, version, hash \\ "residual-hash") do
    Fixtures.Catalog.create_action(
      runner: runner,
      pack_id: version.pack_id,
      pack_version: version.version,
      pack_hash: hash,
      action_id: "#{version.pack_id}.inspect"
    )
  end

  defp drain_queries(queries \\ []) do
    receive do
      {:query, query} -> drain_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
