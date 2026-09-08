defmodule Emisar.ApprovalGrantAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Approvals, Audit, Fixtures, Repo, Runners}

  setup do
    {user, account, owner} = Fixtures.Subjects.owner_subject()
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    membership = Fixtures.Memberships.force_role(membership, "admin")
    admin = Fixtures.Subjects.membership_subject(membership)

    {_secret, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

    %{account: account, owner: owner, admin: admin, membership: membership, key: key}
  end

  describe "revoke_grant/2" do
    test "canonical frozen pack and current runner scope permit offline revocation",
         %{account: _, admin: _, membership: _, key: _} = context do
      runner = Fixtures.Runners.create_runner(account_id: context.account.id, connected?: false)
      Fixtures.Runners.disable_runner(runner)
      grant = grant(context, runner.id)
      {:ok, access} = RunnerAccess.new(:restricted, [], [runner.id], :restricted, ["postgres"])
      Fixtures.Memberships.force_runner_access(context.membership, access)

      assert {:ok, revoked} = Approvals.revoke_grant(grant, context.admin)
      assert revoked.revoked_by_id == context.admin.actor.id
      assert revoked.revoked_at
    end

    test "wildcard runners require all runners, while malformed or deleted targets fail closed",
         %{account: _, admin: _, membership: _, key: _} = context do
      runner = Fixtures.Runners.create_runner(account_id: context.account.id)
      wildcard = grant(context, nil)
      {:ok, selected} = RunnerAccess.new(:restricted, [], [runner.id])
      Fixtures.Memberships.force_runner_access(context.membership, selected)
      assert Approvals.revoke_grant(wildcard, context.admin) == {:error, :not_found}
      Fixtures.Memberships.force_runner_access(context.membership, RunnerAccess.all())
      assert {:ok, _} = Approvals.revoke_grant(wildcard, context.admin)

      invalid = grant(context, runner.id, pack_ref: "postgres@unproven")
      assert Approvals.revoke_grant(invalid, context.admin) == {:error, :not_found}
      deleted = grant(context, runner.id)
      Fixtures.Runners.mark_deleted(runner)
      assert Approvals.revoke_grant(deleted, context.admin) == {:error, :not_found}
      refute Repo.reload!(invalid).revoked_at
      refute Repo.reload!(deleted).revoked_at
    end

    test "a current group move or foreign runner cannot be authorized through the old grant",
         %{account: _, admin: _, membership: _, key: _} = context do
      runner = Fixtures.Runners.create_runner(account_id: context.account.id, group: "staging")
      grant = grant(context, runner.id)
      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [])
      Fixtures.Memberships.force_runner_access(context.membership, access)
      Fixtures.Runners.move_to_group(runner, "production")
      assert Approvals.revoke_grant(grant, context.admin) == {:error, :not_found}
      foreign = Fixtures.Runners.create_runner()
      malformed = grant(context, foreign.id)
      Fixtures.Memberships.force_runner_access(context.membership, RunnerAccess.all())
      assert Approvals.revoke_grant(malformed, context.admin) == {:error, :not_found}
      refute Repo.reload!(grant).revoked_at
      refute Repo.reload!(malformed).revoked_at
    end
  end

  describe "revoke_all_grants/1" do
    test "a scoped manager may revoke the complete set when every target is covered",
         %{account: _, admin: _, membership: _, key: _} = context do
      for _ <- 1..2 do
        runner = Fixtures.Runners.create_runner(account_id: context.account.id, group: "staging")
        grant(context, runner.id)
      end

      {:ok, access} = RunnerAccess.new(:restricted, ["staging"], [], :restricted, ["postgres"])
      Fixtures.Memberships.force_runner_access(context.membership, access)
      assert Approvals.revoke_all_grants(context.admin) == {:ok, 2}
    end

    test "a mixed set is denied before any grant or audit changes",
         %{account: _, admin: _, membership: _, key: _} = context do
      first = Fixtures.Runners.create_runner(account_id: context.account.id)
      second = Fixtures.Runners.create_runner(account_id: context.account.id)
      allowed = grant(context, first.id)
      denied = grant(context, second.id)
      {:ok, access} = RunnerAccess.new(:restricted, [], [first.id])
      Fixtures.Memberships.force_runner_access(context.membership, access)
      events = Repo.all(Audit.Event)

      assert Approvals.revoke_all_grants(context.admin) == {:error, :unauthorized}
      refute Repo.reload!(allowed).revoked_at
      refute Repo.reload!(denied).revoked_at
      assert Repo.all(Audit.Event) == events
    end

    test "a denial in the second target chunk rolls back all grants, while full coverage revokes all",
         %{account: _, admin: _, membership: _, key: _} = context do
      grants =
        for _ <- 1..257 do
          runner = Fixtures.Runners.create_runner(account_id: context.account.id)
          grant(context, runner.id)
        end

      grants
      |> Enum.map(& &1.runner_id)
      |> Enum.max()
      |> Runners.peek_runner_by_id()
      |> Fixtures.Runners.move_to_group("production")

      {:ok, access} = RunnerAccess.new(:restricted, ["default"], [])
      Fixtures.Memberships.force_runner_access(context.membership, access)
      events_before = Repo.all(Audit.Event)
      assert Approvals.revoke_all_grants(context.admin) == {:error, :unauthorized}
      refute Enum.any?(grants, &Repo.reload!(&1).revoked_at)
      assert Repo.all(Audit.Event) == events_before
      Fixtures.Memberships.force_runner_access(context.membership, RunnerAccess.all())

      assert Approvals.revoke_all_grants(context.admin) == {:ok, 257}
      assert Enum.all?(grants, &Repo.reload!(&1).revoked_at)

      events =
        Audit.Event.Query.all()
        |> Audit.Event.Query.by_event_type("approval.grant_revoked")
        |> Repo.all()

      assert length(events) == 257
    end

    test "stale role, user and explicit attenuation never grant revocation",
         %{account: _, admin: _, membership: _, key: _} = context do
      grant = grant(context, nil)
      attenuated = %{context.admin | permissions: MapSet.new()}
      assert Approvals.revoke_grant(grant, attenuated) == {:error, :unauthorized}
      assert Approvals.revoke_all_grants(attenuated) == {:error, :unauthorized}

      Fixtures.Memberships.force_role(context.membership, "operator")
      assert Approvals.revoke_grant(grant, context.admin) == {:error, :unauthorized}
      assert Approvals.revoke_all_grants(context.admin) == {:error, :unauthorized}
      context.membership |> Repo.reload!() |> Fixtures.Memberships.force_role("admin")
      Fixtures.Users.mark_user_as_deleted(context.admin.actor)
      assert Approvals.revoke_grant(grant, context.admin) == {:error, :unauthorized}
      assert Approvals.revoke_all_grants(context.admin) == {:error, :unauthorized}
      refute Repo.reload!(grant).revoked_at
    end

    test "disabled accounts and suspended managers cannot revoke standing grants",
         %{account: _, admin: _, membership: _, key: _} = context do
      grant = grant(context, nil)
      Fixtures.Memberships.suspend_membership(context.membership)
      assert Approvals.revoke_grant(grant, context.admin) == {:error, :unauthorized}
      assert Approvals.revoke_all_grants(context.admin) == {:error, :unauthorized}
      Fixtures.Accounts.disable_account(context.account)
      assert Approvals.revoke_grant(grant, context.admin) == {:error, :unauthorized}
      assert Approvals.revoke_all_grants(context.admin) == {:error, :unauthorized}
      refute Repo.reload!(grant).revoked_at
    end
  end

  describe "update_grant_lifetime_settings/3" do
    test "a scoped manager's zero cap still contains all grants, but a stale manager cannot set it",
         %{account: _, admin: _, membership: _, key: _} = context do
      grant = grant(context, nil)
      Fixtures.Memberships.force_role(context.membership, "operator")

      assert Approvals.update_grant_lifetime_settings(
               context.account,
               %{seconds: 0},
               context.admin
             ) ==
               {:error, :unauthorized}

      refute Repo.reload!(context.account).settings.max_grant_lifetime_seconds
      refute Repo.reload!(grant).revoked_at

      membership =
        context.membership |> Repo.reload!() |> Fixtures.Memberships.force_role("admin")

      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())

      assert {:ok, %{revoked_count: 1}} =
               Approvals.update_grant_lifetime_settings(
                 context.account,
                 %{seconds: 0},
                 context.admin
               )

      assert Repo.reload!(context.account).settings.max_grant_lifetime_seconds == 0
      assert Repo.reload!(grant).revoked_at
    end
  end

  defp grant(context, runner_id, attrs \\ []) do
    Fixtures.Approvals.create_grant(
      Keyword.merge(
        [
          account_id: context.account.id,
          api_key_id: context.key.id,
          granted_by_id: context.admin.actor.id,
          runner_id: runner_id,
          pack_ref: "postgres@1.0.0/sha256:" <> String.duplicate("a", 64)
        ],
        attrs
      )
    )
  end
end
