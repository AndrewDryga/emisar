defmodule Emisar.AccountsOwnerAccessTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures, Repo, SSO}
  alias Emisar.Accounts.{InvitationInput, RunnerAccess}

  test "Owner creation and invitations normalize both dimensions to all" do
    owner = Fixtures.Memberships.create_membership(role: "owner", runner_access_mode: "none")
    assert Accounts.runner_access_for_membership(owner.account_id, owner.id) == RunnerAccess.all()
    assert Fixtures.Memberships.list_runner_scopes(owner) == []

    attrs =
      Fixtures.Accounts.invitation_attrs(
        role: "owner",
        runner_access_mode: "restricted",
        scope: [],
        pack_access_mode: "restricted",
        pack_scope: []
      )

    changeset = InvitationInput.changeset(attrs, [])
    assert {:ok, invitation} = Ecto.Changeset.apply_action(changeset, :insert)
    assert invitation.runner_access == RunnerAccess.all()
    assert invitation.scope == []
    assert invitation.pack_scope == []
  end

  test "promotion preserves scoped agent connections and grants their current membership scope" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.create_subscription(account, "team")
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    subject = Fixtures.Subjects.membership_subject(owner)
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    {:ok, restricted} = RunnerAccess.new(:restricted, ["database"], [], :restricted, ["postgres"])
    target = Fixtures.Memberships.force_runner_access(target, restricted)
    target_subject = Fixtures.Subjects.membership_subject(target)
    session = Fixtures.Auth.create_session_token!(target_subject.actor, :magic_link, nil)

    {raw, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: target.user_id)

    {_other_raw, other_key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: owner.user_id)

    old_subject = Auth.Subject.for_api_key(key, account)
    grant = Fixtures.ApiKeys.create_approved_device_grant(target_subject)
    assert Accounts.runner_access_for_subject(old_subject) == restricted
    assert Accounts.subscribe_account_team(account.id) == :ok

    assert {:ok, promoted} = Accounts.update_membership_role(target, :owner, subject)
    assert promoted.role == :owner
    assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.all()
    assert Fixtures.Memberships.list_runner_scopes(promoted) == []
    assert is_nil(Repo.reload!(key).revoked_at)
    assert Repo.reload!(grant).status == :approved
    assert is_nil(Repo.reload!(other_key).revoked_at)
    assert Emisar.ApiKeys.peek_api_key_by_secret(raw).id == key.id
    assert Accounts.runner_access_for_subject(old_subject) == RunnerAccess.all()
    assert old_subject.role == :api_client
    assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(session)
    user_id = target.user_id
    assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}
  end

  test "promotion does not restore previously revoked credentials" do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    target = Fixtures.Memberships.force_runner_access(target, RunnerAccess.none())

    {raw, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: target.user_id)

    old_subject = Auth.Subject.for_api_key(key, account)
    subject = Fixtures.Subjects.membership_subject(owner)
    assert {:ok, revoked} = Emisar.ApiKeys.revoke_api_key(key, subject)

    assert {:ok, _promoted} = Accounts.update_membership_role(target, :owner, subject)
    assert Repo.reload!(key).revoked_at == revoked.revoked_at
    assert Emisar.ApiKeys.peek_api_key_by_secret(raw) == nil
    assert Accounts.runner_access_for_subject(old_subject) == RunnerAccess.none()
  end

  test "a promotion that already has all runners and packs keeps existing keys" do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: target.user_id)

    subject = Fixtures.Subjects.membership_subject(owner)
    assert Accounts.subscribe_account_team(account.id) == :ok

    assert {:ok, _promoted} = Accounts.update_membership_role(target, :owner, subject)
    assert is_nil(Repo.reload!(key).revoked_at)

    assert Accounts.runner_access_for_subject(Auth.Subject.for_api_key(key, account)) ==
             RunnerAccess.all()

    user_id = target.user_id
    assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}
  end

  test "Owner access cannot be edited and the target account remains authoritative" do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    foreign = Fixtures.Memberships.create_membership(role: "owner")
    subject = Fixtures.Subjects.membership_subject(owner)

    assert Accounts.update_membership_runner_access(target, RunnerAccess.none(), subject) ==
             {:error, :owner_access_is_account_wide}

    assert Accounts.update_membership_runner_access(foreign, RunnerAccess.none(), subject) ==
             {:error, :unauthorized}

    assert {:ok, facts} = Accounts.fetch_team_member_facts(target.id, subject)
    refute facts.runner_access_editable?
    assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.all()
  end

  test "promotion requires Owner authority and cannot cross accounts" do
    account = Fixtures.Accounts.create_account()
    operator = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
    admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
    foreign_owner = Fixtures.Memberships.create_membership(role: "owner")

    assert Accounts.update_membership_role(
             target,
             :owner,
             Fixtures.Subjects.membership_subject(operator)
           ) ==
             {:error, :unauthorized}

    assert Accounts.update_membership_role(
             target,
             :owner,
             Fixtures.Subjects.membership_subject(admin)
           ) ==
             {:error, :insufficient_privileges}

    assert Accounts.update_membership_role(
             target,
             :owner,
             Fixtures.Subjects.membership_subject(foreign_owner)
           ) ==
             {:error, :unauthorized}

    assert Accounts.return_owner_to_directory(
             target,
             Fixtures.Subjects.membership_subject(operator)
           ) ==
             {:error, :unauthorized}

    assert Accounts.return_owner_to_directory(
             target,
             Fixtures.Subjects.membership_subject(foreign_owner)
           ) ==
             {:error, :unauthorized}

    assert Repo.reload!(target).role == :operator
  end

  test "demotion requires an explicit runner and pack grant" do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    subject = Fixtures.Subjects.membership_subject(owner)
    {:ok, access} = RunnerAccess.new(:restricted, [], [runner.id], :restricted, ["postgres"])

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: target.user_id)

    grant =
      Fixtures.ApiKeys.create_approved_device_grant(Fixtures.Subjects.membership_subject(target))

    assert Accounts.subscribe_account_team(account.id) == :ok

    assert Accounts.update_membership_role(target, :admin, subject) ==
             {:error, :owner_demotion_requires_access}

    assert {:ok, demoted} =
             Accounts.update_membership_role(target, :admin, subject, runner_access: access)

    assert demoted.role == :admin
    assert Accounts.runner_access_for_membership(account.id, target.id) == access
    assert Fixtures.Memberships.list_runner_scopes(demoted) == [{:runner, runner.id}]
    assert Repo.reload!(key).revoked_at
    assert Repo.reload!(grant).status == :denied
    user_id = target.user_id
    assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}
  end

  test "a foreign runner in the demotion grant rolls back role and credential changes" do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    foreign_runner = Fixtures.Runners.create_runner()

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: target.user_id)

    subject = Fixtures.Subjects.membership_subject(owner)
    {:ok, access} = RunnerAccess.restricted([], [foreign_runner.id])

    assert Accounts.update_membership_role(target, :admin, subject, runner_access: access) ==
             {:error, :invalid_runner_access}

    assert Repo.reload!(target).role == :owner
    assert is_nil(Repo.reload!(key).revoked_at)
    assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.all()
  end

  test "a stale Owner demotion form cannot change a member who is no longer an Owner" do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    snapshot = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    Fixtures.Memberships.force_role(snapshot, "admin")
    subject = Fixtures.Subjects.membership_subject(owner)

    assert Accounts.update_membership_role(snapshot, :viewer, subject,
             runner_access: RunnerAccess.none(),
             expected_role: :owner
           ) == {:error, :membership_role_changed}

    assert Repo.reload!(snapshot).role == :admin
  end

  describe "return_owner_to_directory/2" do
    test "directory return persists canonical none until the provider grants its role and access" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "enterprise")
      owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      provider =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          default_role: :operator,
          default_runner_access_mode: :all
        )
        |> Fixtures.SSO.enable_scim()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          runner_access_directory_managed: true,
          directory_provider_id: provider.id
        )

      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        user_id: target.user_id
      )

      subject = Fixtures.Subjects.membership_subject(owner)
      assert Accounts.subscribe_account_team(account.id) == :ok

      assert {:ok, pending} = Accounts.return_owner_to_directory(target, subject)
      assert pending.role == :viewer
      assert pending.directory_managed
      assert pending.runner_access_directory_managed
      assert is_integer(pending.directory_authorization_pending_version)
      assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.none()

      assert Fixtures.Memberships.list_runner_scopes(pending) ==
               RunnerAccess.scope_tuples(RunnerAccess.none())

      user_id = target.user_id
      assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}

      assert SSO.reconcile_pending_authorizations() == :ok
      assert Repo.reload!(target).role == :operator
      assert Repo.reload!(target).directory_authorization_pending_version == nil
      assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.all()
    end

    test "denies an Operator and an Owner from another account without changing the target" do
      account = Fixtures.Accounts.create_account()
      target = Fixtures.Memberships.create_membership(account_id: account.id, role: :owner)
      operator = Fixtures.Memberships.create_membership(account_id: account.id, role: :operator)
      foreign_owner = Fixtures.Memberships.create_membership(role: :owner)

      for member <- [operator, foreign_owner] do
        assert Accounts.return_owner_to_directory(
                 target,
                 Fixtures.Subjects.membership_subject(member)
               ) ==
                 {:error, :unauthorized}
      end

      assert Repo.reload!(target).role == :owner
      assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.all()
    end
  end

  test "Owner-wide grants do not bypass pending invitations, directory fences or suspension" do
    invited =
      Fixtures.Memberships.create_membership(role: "owner", invitation_token_digest: "pending")

    pending =
      Fixtures.Memberships.create_membership(
        role: "owner",
        directory_authorization_pending_version: 1
      )

    suspended =
      Fixtures.Memberships.create_membership(role: "owner")
      |> Fixtures.Memberships.suspend_membership()

    for member <- [invited, pending, suspended] do
      assert Accounts.runner_access_for_membership(member.account_id, member.id) ==
               RunnerAccess.none()
    end
  end

  test "routine directory reconciliation preserves an already account-wide Owner key" do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: owner.user_id)

    owner = Fixtures.Memberships.mark_directory_authorization_pending(owner, 0)
    assert Accounts.subscribe_account_team(account.id) == :ok

    assert {:ok, updated} =
             Accounts.sync_set_membership_authorization(
               owner,
               :viewer,
               RunnerAccess.none(),
               provider
             )

    assert updated.role == :owner
    assert Accounts.runner_access_for_membership(account.id, owner.id) == RunnerAccess.all()
    assert is_nil(Repo.reload!(key).revoked_at)
    user_id = owner.user_id
    assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}
  end
end
