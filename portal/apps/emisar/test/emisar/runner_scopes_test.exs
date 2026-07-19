defmodule Emisar.RunnerAccessTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Fixtures, Repo, Runners, Runs}

  describe "RunnerAccess" do
    test "normalizes restricted access and rejects ambiguous shapes" do
      runner_id = Ecto.UUID.generate()

      assert {:ok,
              %RunnerAccess{
                mode: :restricted,
                groups: ["app", "db"],
                runner_ids: [^runner_id]
              }} = RunnerAccess.restricted([" db ", "app", "db"], [runner_id, runner_id])

      assert {:error, :invalid_runner_access} = RunnerAccess.new(:restricted, [], [])
      assert {:error, :invalid_runner_access} = RunnerAccess.new(:none, ["db"], [])
      assert {:error, :invalid_runner_access} = RunnerAccess.new(:all, [], [runner_id])
      assert {:error, :invalid_runner_access} = RunnerAccess.new(:restricted, [], ["not-a-uuid"])
    end

    test "unions directory grants with all dominance" do
      runner_id = Ecto.UUID.generate()
      {:ok, group_access} = RunnerAccess.restricted(["db"], [])
      {:ok, runner_access} = RunnerAccess.restricted([], [runner_id])

      assert RunnerAccess.union([RunnerAccess.none(), group_access, runner_access]) ==
               %RunnerAccess{mode: :restricted, groups: ["db"], runner_ids: [runner_id]}

      assert RunnerAccess.union([group_access, RunnerAccess.all()]) == RunnerAccess.all()
    end

    test "coverage is monotonic and explicit" do
      {:ok, db} = RunnerAccess.restricted(["db"], [])
      {:ok, db_and_app} = RunnerAccess.restricted(["db", "app"], [])

      assert RunnerAccess.covers?(RunnerAccess.all(), db_and_app)
      assert RunnerAccess.covers?(db_and_app, db)
      assert RunnerAccess.covers?(db, RunnerAccess.none())
      refute RunnerAccess.covers?(db, db_and_app)
      refute RunnerAccess.covers?(RunnerAccess.none(), db)
    end
  end

  describe "update_membership_runner_access/3" do
    setup do
      {account, owner, owner_subject} = account_with_owner()
      member = create_member(account, "operator")
      member_subject = Fixtures.Subjects.membership_subject(member)

      %{
        account: account,
        owner: owner,
        owner_subject: owner_subject,
        member: member,
        member_subject: member_subject
      }
    end

    test "new account owners explicitly receive all access", %{
      account: account,
      owner: owner
    } do
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert membership.runner_access_mode == :all

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               RunnerAccess.all()
    end

    test "none, all, and restricted remain distinct", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject
    } do
      db = Fixtures.Runners.create_runner(account_id: account.id, name: "db-1", group: "db")
      edge = Fixtures.Runners.create_runner(account_id: account.id, name: "edge-1", group: "edge")
      _app = Fixtures.Runners.create_runner(account_id: account.id, name: "app-1", group: "app")

      assert {:ok, all_runners, %{count: 3}} = Runners.list_runners_for_account(member_subject)
      assert Enum.sort(Enum.map(all_runners, & &1.name)) == ["app-1", "db-1", "edge-1"]

      assert {:ok, _membership} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.none(),
                 owner_subject
               )

      assert {:ok, [], %{count: 0}} = Runners.list_runners_for_account(member_subject)

      {:ok, restricted} = RunnerAccess.restricted(["db"], [edge.id])

      assert {:ok, updated} =
               Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert updated.runner_access_mode == :restricted
      assert Accounts.runner_access_for_membership(account.id, member.id) == restricted
      assert {:ok, scoped, %{count: 2}} = Runners.list_runners_for_account(member_subject)
      assert Enum.sort(Enum.map(scoped, & &1.name)) == ["db-1", "edge-1"]
      assert {:ok, fetched_db} = Runners.fetch_runner_by_id(db.id, member_subject)
      assert fetched_db.id == db.id
    end

    test "every mode transition keeps the legacy scope mirror exact", %{
      account: account,
      owner_subject: owner_subject,
      member: member
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      {:ok, restricted} = RunnerAccess.restricted(["db"], [runner.id])

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.none(),
                 owner_subject
               )

      assert legacy_scope_rows(member.id) == [
               {"runner", "00000000-0000-0000-0000-000000000000"}
             ]

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert legacy_scope_rows(member.id) == [
               {"group", "db"},
               {"runner", runner.id}
             ]

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.all(),
                 owner_subject
               )

      assert legacy_scope_rows(member.id) == []
    end

    test "rejects an individual runner from another account", %{
      owner_subject: owner_subject,
      member: member
    } do
      foreign_runner = Fixtures.Runners.create_runner()
      {:ok, foreign_access} = RunnerAccess.restricted([], [foreign_runner.id])

      assert {:error, :invalid_runner_access} =
               Accounts.update_membership_runner_access(
                 member,
                 foreign_access,
                 owner_subject
               )
    end

    test "single-runner reads hide out-of-scope runners", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "app-1", group: "app")
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert Runners.fetch_runner_by_id(runner.id, member_subject) == {:error, :not_found}
      assert Runners.fetch_runner_by_name(runner.name, member_subject) == {:error, :not_found}
    end

    test "inactive, deleted, missing, and malformed memberships fail closed", %{
      account: account,
      owner_subject: owner_subject,
      member: member
    } do
      assert Accounts.runner_access_for_membership(account.id, "bad-id") == RunnerAccess.none()

      malformed = Fixtures.Memberships.create_membership(account_id: account.id)

      from(m in Accounts.Membership, where: m.id == ^malformed.id)
      |> Repo.update_all(set: [runner_access_mode: :none])

      assert Accounts.runner_access_for_membership(account.id, malformed.id) ==
               RunnerAccess.none()

      suspended = Fixtures.Memberships.suspend_membership(member)

      assert Accounts.runner_access_for_membership(account.id, suspended.id) ==
               RunnerAccess.none()

      other = create_member(account, "viewer")

      {:ok, _membership} =
        Accounts.update_membership_runner_access(other, RunnerAccess.none(), owner_subject)

      deleted = Fixtures.Memberships.mark_membership_as_deleted(other)
      assert Accounts.runner_access_for_membership(account.id, deleted.id) == RunnerAccess.none()
    end

    test "directory-owned access refuses manual edits", %{
      account: account,
      owner_subject: owner_subject
    } do
      managed =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          runner_access_directory_managed: true
        )

      assert {:error, :runner_access_managed_by_directory} =
               Accounts.update_membership_runner_access(
                 managed,
                 RunnerAccess.none(),
                 owner_subject
               )
    end

    test "an operator cannot edit runner access", %{
      member: member,
      member_subject: member_subject
    } do
      assert {:error, :unauthorized} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.none(),
                 member_subject
               )
    end

    test "cross-account edits are denied" do
      {account_a, _owner_a, subject_a} = account_with_owner()
      {account_b, _owner_b, _subject_b} = account_with_owner()
      member_b = create_member(account_b, "operator")

      assert account_a.id != account_b.id

      assert {:error, :unauthorized} =
               Accounts.update_membership_runner_access(
                 member_b,
                 RunnerAccess.none(),
                 subject_a
               )
    end

    test "a restricted admin cannot delegate beyond current access", %{
      account: account,
      owner_subject: owner_subject,
      member: target
    } do
      admin = create_member(account, "admin")
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])
      {:ok, _admin} = Accounts.update_membership_runner_access(admin, db_access, owner_subject)
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      assert {:ok, _target} =
               Accounts.update_membership_runner_access(target, db_access, admin_subject)

      assert {:error, :runner_access_exceeds_subject} =
               Accounts.update_membership_runner_access(
                 target,
                 RunnerAccess.all(),
                 admin_subject
               )
    end

    test "writes one explicit before/after audit event", %{
      account: account,
      owner_subject: owner_subject,
      member: member
    } do
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])
      {:ok, _member} = Accounts.update_membership_runner_access(member, restricted, owner_subject)

      event =
        Emisar.Audit.Event.Query.all()
        |> Emisar.Audit.Event.Query.by_account_id(account.id)
        |> Emisar.Audit.Event.Query.by_event_type("membership.runner_access_changed")
        |> Repo.one!()

      assert event.payload["before"] == %{
               "mode" => "all",
               "groups" => [],
               "runner_ids" => []
             }

      assert event.payload["after"] == %{
               "mode" => "restricted",
               "groups" => ["db"],
               "runner_ids" => []
             }
    end
  end

  describe "runner_access_for_subject/1" do
    test "re-reads the current active membership instead of trusting subject state" do
      {account, owner, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)
      assert Accounts.runner_access_for_subject(subject) == RunnerAccess.all()

      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
      assert Accounts.runner_access_for_subject(subject) == RunnerAccess.none()

      unbound = Fixtures.Subjects.build_subject(account: account, membership_id: nil)
      assert Accounts.runner_access_for_subject(unbound) == RunnerAccess.none()
    end
  end

  describe "runner_access_for_membership/2" do
    test "returns explicit access only for a current membership in that account" do
      {account, owner, _subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               RunnerAccess.all()

      assert Accounts.runner_access_for_membership(Ecto.UUID.generate(), membership.id) ==
               RunnerAccess.none()
    end
  end

  describe "runner_access_for_memberships/1" do
    test "batches explicit modes without an N+1 read" do
      {account, _owner, owner_subject} = account_with_owner()
      all_member = create_member(account, "operator")
      none_member = create_member(account, "viewer")

      {:ok, none_member} =
        Accounts.update_membership_runner_access(
          none_member,
          RunnerAccess.none(),
          owner_subject
        )

      assert Accounts.runner_access_for_memberships([all_member, none_member]) == %{
               all_member.id => RunnerAccess.all(),
               none_member.id => RunnerAccess.none()
             }
    end
  end

  describe "runner_access_for_locked_membership/2" do
    test "loads the explicit aggregate through the caller's transaction repo" do
      {account, owner, _subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert Accounts.runner_access_for_locked_membership(Repo, membership) ==
               RunnerAccess.all()

      assert membership.account_id == account.id
    end
  end

  describe "fetch_and_lock_active_membership/3" do
    test "returns only the active membership in the requested account" do
      {account, owner, _subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert {:ok, locked} =
               Accounts.fetch_and_lock_active_membership(Repo, account.id, membership.id)

      assert locked.id == membership.id

      suspended = Fixtures.Memberships.suspend_membership(membership)

      assert {:error, :not_found} =
               Accounts.fetch_and_lock_active_membership(Repo, account.id, suspended.id)
    end
  end

  describe "validate_runner_access_for_account/2" do
    test "accepts local individual runners and rejects foreign ones" do
      account = Fixtures.Accounts.create_account()
      local = Fixtures.Runners.create_runner(account_id: account.id)
      foreign = Fixtures.Runners.create_runner()
      {:ok, local_access} = RunnerAccess.restricted([], [local.id])
      {:ok, foreign_access} = RunnerAccess.restricted([], [foreign.id])

      assert :ok = Accounts.validate_runner_access_for_account(account.id, local_access)

      assert {:error, :invalid_runner_access} =
               Accounts.validate_runner_access_for_account(account.id, foreign_access)
    end
  end

  describe "mark_directory_authorization_pending/5" do
    test "marks provider-owned memberships and atomically adopts unmanaged identities" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      managed =
        create_member(account, "operator",
          directory_provider_id: provider.id,
          runner_access_directory_managed: true
        )

      local = create_member(account, "operator")

      assert {:ok, 7} =
               Accounts.mark_directory_authorization_pending(
                 Repo,
                 account.id,
                 provider.id,
                 [managed.user_id, local.user_id],
                 7
               )

      assert Repo.reload!(managed).directory_authorization_pending_version == 7

      adopted = Repo.reload!(local)
      assert adopted.directory_authorization_pending_version == 7
      assert adopted.directory_provider_id == provider.id
      assert adopted.runner_access_directory_managed
    end

    test "does not let a second directory provider take over an owned membership" do
      account = Fixtures.Accounts.create_account()
      owner_provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      other_provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :jumpcloud)

      member =
        create_member(account, "admin",
          directory_provider_id: owner_provider.id,
          runner_access_directory_managed: true
        )

      assert {:ok, 4} =
               Accounts.mark_directory_authorization_pending(
                 Repo,
                 account.id,
                 other_provider.id,
                 [member.user_id],
                 4
               )

      unchanged = Repo.reload!(member)
      assert unchanged.directory_provider_id == owner_provider.id
      assert is_nil(unchanged.directory_authorization_pending_version)

      assert {:error, :directory_authorization_provider_conflict} =
               Accounts.sync_set_membership_authorization(
                 unchanged,
                 :viewer,
                 RunnerAccess.none(),
                 other_provider
               )
    end
  end

  describe "list_pending_directory_authorizations/1" do
    test "returns a bounded pending work set" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      memberships =
        for _ <- 1..2 do
          create_member(account, "operator",
            directory_provider_id: provider.id,
            runner_access_directory_managed: true,
            directory_authorization_pending_version: 3
          )
        end

      assert [pending] = Accounts.list_pending_directory_authorizations(1)
      assert pending.id in Enum.map(memberships, & &1.id)
    end
  end

  describe "ensure_runner_access_grant_allowed/2" do
    test "permits only grants covered by the caller's current access" do
      {account, _owner, owner_subject} = account_with_owner()
      admin = create_member(account, "admin")
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])
      {:ok, _admin} = Accounts.update_membership_runner_access(admin, db_access, owner_subject)
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      assert Accounts.ensure_runner_access_grant_allowed(admin_subject, db_access) == :ok

      assert Accounts.ensure_runner_access_grant_allowed(admin_subject, RunnerAccess.all()) ==
               {:error, :runner_access_exceeds_subject}
    end
  end

  describe "sync_set_membership_authorization/4" do
    test "atomically marks both role and runner access as directory managed" do
      {account, _owner, _owner_subject} = account_with_owner()
      member = create_member(account, "viewer")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      {:ok, access} = RunnerAccess.restricted(["production"], [])

      assert {:ok, updated} =
               Accounts.sync_set_membership_authorization(
                 member,
                 :operator,
                 access,
                 provider
               )

      assert updated.role == :operator
      assert updated.directory_managed
      assert updated.runner_access_directory_managed
      assert Accounts.runner_access_for_membership(account.id, member.id) == access
    end

    test "a human owner keeps the owner role while directory runner access still reconciles" do
      {account, owner, _owner_subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      assert {:ok, updated} =
               Accounts.sync_set_membership_authorization(
                 membership,
                 :viewer,
                 RunnerAccess.none(),
                 provider
               )

      assert updated.role == :owner
      refute updated.directory_managed
      assert updated.runner_access_directory_managed
      assert updated.directory_provider_id == provider.id

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               RunnerAccess.none()
    end
  end

  describe "runner_in_scope?/2" do
    test "accepts only runners covered by the explicit access value" do
      runner = %{id: Ecto.UUID.generate(), group: "db"}
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      assert Runners.runner_in_scope?(runner, RunnerAccess.all())
      assert Runners.runner_in_scope?(runner, db_access)
      refute Runners.runner_in_scope?(runner, RunnerAccess.none())
      refute Runners.runner_in_scope?(runner, nil)
    end
  end

  describe "enforcement at dispatch time" do
    test "the authenticated membership is re-read and forged attrs are ignored" do
      {account, owner, owner_subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      _membership = Fixtures.Memberships.force_runner_access(membership, restricted)

      forged = create_member(account, "operator")

      assert {:error, :runner_out_of_scope} =
               Runs.dispatch_run(
                 %{
                   runner_id: runner.id,
                   action_id: "x.y",
                   reason: "test",
                   requested_by_membership_id: forged.id
                 },
                 owner_subject
               )
    end

    test "an offline queued run is not sent after its initiating access is revoked" do
      {account, owner, owner_subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")
      _action = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          reason: "test current authorization",
          requested_by_id: owner.id,
          initiating_membership_id: membership.id,
          args: %{}
        })

      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
      :ok = Runners.subscribe_runner_transport(runner)

      assert {:error, :initiator_no_longer_authorized} = Runs.dispatch_to_runner(run)
      assert Runs.peek_run_by_id(run.id).status == :pending
      refute_receive {:cloud_to_runner, _generation, _payload}, 100

      assert Accounts.runner_access_for_subject(owner_subject) == RunnerAccess.none()
    end
  end

  describe "mixed-revision database guard" do
    test "an old membership insert gets an explicit fail-closed mode" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      membership_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {:ok, _result} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 """
                 INSERT INTO account_memberships
                   (id, account_id, user_id, role, inserted_at, updated_at)
                 VALUES ($1, $2, $3, 'operator', $4, $4)
                 """,
                 [
                   Ecto.UUID.dump!(membership_id),
                   Ecto.UUID.dump!(account.id),
                   Ecto.UUID.dump!(user.id),
                   now
                 ]
               )

      assert Accounts.runner_access_for_membership(account.id, membership_id) ==
               RunnerAccess.none()
    end

    test "an old owner insert preserves the initial-owner all-access exception" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      membership_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {:ok, _result} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 """
                 INSERT INTO account_memberships
                   (id, account_id, user_id, role, inserted_at, updated_at)
                 VALUES ($1, $2, $3, 'owner', $4, $4)
                 """,
                 [
                   Ecto.UUID.dump!(membership_id),
                   Ecto.UUID.dump!(account.id),
                   Ecto.UUID.dump!(user.id),
                   now
                 ]
               )

      assert Accounts.runner_access_for_membership(account.id, membership_id) ==
               RunnerAccess.all()
    end

    test "old direct scope writes cannot erase explicit none" do
      account = Fixtures.Accounts.create_account()
      member = create_member(account, "operator", runner_access_mode: "none")

      assert_raise Postgrex.Error,
                   ~r/runner access must be written through the explicit aggregate/,
                   fn ->
                     Ecto.Adapters.SQL.query!(
                       Repo,
                       "DELETE FROM user_runner_scopes WHERE membership_id = $1",
                       [Ecto.UUID.dump!(member.id)]
                     )
                   end
    end

    test "the aggregate writer capability does not leak through an outer transaction" do
      {account, _owner, owner_subject} = account_with_owner()
      member = create_member(account, "operator")

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.none(),
                 owner_subject
               )

      assert_raise Postgrex.Error,
                   ~r/runner access must be written through the explicit aggregate/,
                   fn ->
                     Ecto.Adapters.SQL.query!(
                       Repo,
                       "DELETE FROM user_runner_scopes WHERE membership_id = $1",
                       [Ecto.UUID.dump!(member.id)]
                     )
                   end
    end
  end

  defp legacy_scope_rows(membership_id) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT scope_type, scope_value
        FROM user_runner_scopes
        WHERE membership_id = $1
        ORDER BY scope_type, scope_value
        """,
        [Ecto.UUID.dump!(membership_id)]
      )

    Enum.map(rows, fn [scope_type, scope_value] -> {scope_type, scope_value} end)
  end

  defp create_member(account, role, attrs \\ []) do
    user = Fixtures.Users.create_user()

    attrs =
      attrs
      |> Keyword.merge(account_id: account.id, user_id: user.id, role: role)

    Fixtures.Memberships.create_membership(attrs)
  end

  defp account_with_owner do
    user = Fixtures.Users.create_user()

    {:ok, account} =
      Accounts.create_account_with_owner(
        %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
        user
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {account, user, subject}
  end
end
