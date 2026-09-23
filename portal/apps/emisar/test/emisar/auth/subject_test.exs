defmodule Emisar.Auth.SubjectTest do
  @moduledoc """
  Foundational invariants for `Auth.Subject` — how role + actor kind
  shape the permission set, and that constructors never crash on the
  bootstrap-time edge cases (system subject, missing account).
  """
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Account
  alias Emisar.Accounts.Membership
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures
  alias Emisar.RequestContext
  alias Emisar.Runners.Runner
  alias Emisar.Users.User

  describe "human_membership_id/1" do
    test "uses the exact human seat, never a machine's owner or a system actor" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      assert Subject.human_membership_id(subject) == subject.membership_id

      assert Subject.human_membership_id(%{
               subject
               | actor: %Membership{id: subject.membership_id}
             }) == subject.membership_id

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      machine = Subject.for_api_key(key, account)
      assert machine.membership_id == subject.membership_id
      assert is_nil(Subject.human_membership_id(machine))
      assert is_nil(Subject.human_membership_id(%Subject{}))
    end
  end

  describe "for_member/4" do
    setup do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      %{user: user, account: account}
    end

    test "owner gets the full owner-role permission set", %{user: user, account: account} do
      membership = %Membership{role: :owner, user_id: user.id, user: user, account_id: account.id}

      subject = Subject.for_member(membership, account)

      assert subject.role == :owner
      assert subject.actor == user
      assert subject.account == account
      assert MapSet.size(subject.permissions) > 0
      # An owner-specific permission held by no other role.
      assert MapSet.member?(
               subject.permissions,
               Emisar.Accounts.Authorizer.manage_security_settings_permission()
             )
    end

    test "viewer holds strictly fewer permissions than admin", %{user: user, account: account} do
      viewer = %Membership{role: :viewer, user_id: user.id, user: user, account_id: account.id}
      admin = %Membership{role: :admin, user_id: user.id, user: user, account_id: account.id}
      viewer_subj = Subject.for_member(viewer, account)
      admin_subj = Subject.for_member(admin, account)

      # Admin is a strict superset of viewer.
      assert MapSet.subset?(viewer_subj.permissions, admin_subj.permissions)
      assert MapSet.size(viewer_subj.permissions) < MapSet.size(admin_subj.permissions)
    end

    test "pending directory authorization is viewer-only except for a human owner", %{
      user: user,
      account: account
    } do
      admin = %Membership{
        role: :admin,
        user_id: user.id,
        user: user,
        account_id: account.id,
        directory_authorization_pending_version: 3
      }

      owner = %Membership{
        role: :owner,
        user_id: user.id,
        user: user,
        account_id: account.id,
        directory_authorization_pending_version: 3
      }

      pending_admin = Subject.for_member(admin, account)
      pending_owner = Subject.for_member(owner, account)

      assert pending_admin.role == :viewer
      assert pending_admin.permissions == Emisar.Auth.Permissions.for_role(:viewer)
      assert pending_owner.role == :owner
      assert pending_owner.permissions == Emisar.Auth.Permissions.for_role(:owner)
    end

    test "an unresolved invitation has no role or permissions", %{
      user: user,
      account: account
    } do
      invited = %Membership{
        role: :owner,
        user_id: user.id,
        user: user,
        account_id: account.id,
        invitation_token_digest: "pending-digest"
      }

      pending = Subject.for_member(invited, account)

      assert pending.role == nil
      assert pending.permissions == MapSet.new()
    end

    test "a direct membership with no invitation fields remains authorized", %{
      user: user,
      account: account
    } do
      membership = %Membership{role: :admin, user_id: user.id, user: user, account_id: account.id}

      direct = Subject.for_member(membership, account)

      assert direct.role == :admin
      assert direct.permissions == Emisar.Auth.Permissions.for_role(:admin)
    end

    test "a Member without a personal login is its own actor", %{account: account} do
      membership = Fixtures.Memberships.create_unlinked_membership(account_id: account.id)

      subject = Subject.for_member(membership, account)

      assert subject.actor == membership
      assert Subject.actor_kind(subject) == "membership"
      assert Subject.human_membership_id(subject) == membership.id
      assert Subject.user_id(subject) == nil
      assert Subject.personal_denial(subject) == {:error, :personal_login_required}
    end
  end

  describe "Authorizer.permissions_for/1" do
    test "returns an empty set for unknown roles" do
      assert MapSet.size(Emisar.Auth.Permissions.for_role(:nope)) == 0
    end
  end

  describe "Authorizer.ensure_has_permissions/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      %{account: account, user: user}
    end

    test ":ok when the subject holds the permission", %{account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      assert Emisar.Auth.Authorizer.ensure_has_permissions(
               subject,
               Emisar.Accounts.Authorizer.manage_security_settings_permission()
             ) == :ok
    end

    test "{:error, :unauthorized} when the subject lacks it", %{account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :viewer)

      assert Emisar.Auth.Authorizer.ensure_has_permissions(
               subject,
               Emisar.Accounts.Authorizer.manage_security_settings_permission()
             ) == {:error, :unauthorized}
    end

    test "{:one_of, [...]} succeeds if any one permission is held", %{
      account: account,
      user: user
    } do
      operator = Fixtures.Subjects.subject_for(user, account, role: :operator)

      # Operator does NOT hold manage_runners but DOES hold view_runners.
      perms = [
        Emisar.Runners.Authorizer.manage_runners_permission(),
        Emisar.Runners.Authorizer.view_runners_permission()
      ]

      assert Emisar.Auth.Authorizer.ensure_has_permissions(operator, {:one_of, perms}) == :ok
    end

    test "rejects {:one_of, [...]} if the subject holds none", %{account: account, user: user} do
      viewer = Fixtures.Subjects.subject_for(user, account, role: :viewer)

      perms = [
        Emisar.Accounts.Authorizer.manage_security_settings_permission(),
        Emisar.Accounts.Authorizer.manage_team_permission()
      ]

      assert Emisar.Auth.Authorizer.ensure_has_permissions(viewer, {:one_of, perms}) ==
               {:error, :unauthorized}
    end

    test "a plain list requires ALL permissions — holding every one passes", %{
      account: account,
      user: user
    } do
      owner = Fixtures.Subjects.subject_for(user, account, role: :owner)

      # Owner holds both of these.
      perms = [
        Emisar.Accounts.Authorizer.manage_security_settings_permission(),
        Emisar.Accounts.Authorizer.manage_team_permission()
      ]

      assert Emisar.Auth.Authorizer.ensure_has_permissions(owner, perms) == :ok
    end

    test "a plain list is rejected when the subject lacks any one of them", %{
      account: account,
      user: user
    } do
      admin = Fixtures.Subjects.subject_for(user, account, role: :admin)

      # Admin holds manage_team but NOT manage_owners (owner-only), so requiring
      # both fails — a permission list requires ALL of them.
      perms = [
        Emisar.Accounts.Authorizer.manage_team_permission(),
        Emisar.Accounts.Authorizer.manage_owners_permission()
      ]

      assert Emisar.Auth.Authorizer.ensure_has_permissions(admin, perms) ==
               {:error, :unauthorized}
    end

    test "an actor the gate cannot re-check is refused despite its permissions", %{
      account: account,
      user: user
    } do
      owner = Fixtures.Subjects.subject_for(user, account, role: :owner)
      unknown = %{owner | actor: account}

      assert Emisar.Auth.Authorizer.ensure_has_permissions(
               unknown,
               Emisar.Runners.Authorizer.view_runners_permission()
             ) == {:error, :unauthorized}

      assert Emisar.Runners.list_runners_for_account(unknown) == {:error, :unauthorized}
    end

    test "a Member actor is re-read through its own grant and cannot borrow a linked one", %{
      account: account,
      user: user
    } do
      permission = Emisar.Runners.Authorizer.view_runners_permission()
      owner = Fixtures.Subjects.subject_for(user, account, role: :owner)
      team = Fixtures.Accounts.create_account(plan: "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: team.id)
      membership = Fixtures.Memberships.create_unlinked_membership(account_id: team.id)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: team.id,
          provider_id: provider.id,
          membership: membership
        )

      raw = Fixtures.Auth.create_member_session_token!(membership, identity)
      member = Fixtures.Subjects.unlinked_member_subject(membership, raw)
      borrowed = %{owner | actor: %Membership{id: owner.membership_id}}

      assert Emisar.Auth.Authorizer.ensure_has_permissions(member, permission) == :ok

      assert Emisar.Auth.Authorizer.ensure_has_permissions(borrowed, permission) ==
               {:error, :unauthorized}

      Fixtures.Memberships.suspend_membership(membership)

      assert Emisar.Auth.Authorizer.ensure_has_permissions(member, permission) ==
               {:error, :unauthorized}
    end

    test "API key and actorless support subjects keep their own authority", %{
      account: account,
      user: user
    } do
      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      support =
        Fixtures.Subjects.build_subject(
          account: account,
          role: :owner,
          permissions: Emisar.Auth.Permissions.for_role(:owner)
        )

      for subject <- [Subject.for_api_key(key, account), support] do
        assert Emisar.Auth.Authorizer.ensure_has_permissions(
                 subject,
                 Emisar.Runners.Authorizer.view_runners_permission()
               ) == :ok
      end
    end
  end

  describe "for_api_key/3" do
    test "carries the api_client role, the key's creator membership, and the request context" do
      account = %Account{id: "acct-1"}
      key = %ApiKey{id: "key-1", created_by_membership_id: "mem-1"}
      context = %RequestContext{ip_address: "10.0.0.9"}

      subject = Subject.for_api_key(key, account, context)

      assert subject.role == :api_client
      assert subject.actor == key
      assert subject.account == account
      # The minting membership rides along so MCP can apply per-user runner ACLs.
      assert subject.membership_id == "mem-1"
      assert subject.context == context
      assert subject.permissions == Emisar.Auth.Permissions.for_role(:api_client)
    end

    test "membership_id is nil when the key has no creator membership" do
      subject = Subject.for_api_key(%ApiKey{id: "key-2"}, %Account{id: "acct-1"})
      assert subject.membership_id == nil
    end
  end

  describe "for_runner/3" do
  end

  describe "actor_kind/1 + actor_id/1" do
    test "classify each actor, with system/nil fallbacks for an actor-less subject" do
      user_subject = %Subject{actor: %User{id: "u1", email: "ops@example.test"}}
      key_subject = %Subject{actor: %ApiKey{id: "k1"}}
      runner_subject = %Subject{actor: %Runner{id: "r1"}}
      actorless = %Subject{}

      assert Subject.actor_kind(user_subject) == "membership"
      assert Subject.actor_kind(key_subject) == "api_key"
      assert Subject.actor_kind(runner_subject) == "runner"
      assert Subject.actor_kind(actorless) == "system"

      assert Subject.actor_id(user_subject) == "u1"
      assert Subject.actor_id(key_subject) == "k1"
      assert Subject.actor_id(actorless) == nil
    end

    test "user_id/1 is the user actor's id, nil for a key/runner/actor-less subject" do
      user_subject = %Subject{actor: %User{id: "u1"}}
      key_subject = %Subject{actor: %ApiKey{id: "k1"}}
      runner_subject = %Subject{actor: %Runner{id: "r1"}}

      # A user-FK attribution column takes user_id — an API key's actor_id is the
      # KEY id, which would violate a users FK, so keys/runners resolve to nil.
      assert Subject.user_id(user_subject) == "u1"
      assert Subject.user_id(key_subject) == nil
      assert Subject.user_id(runner_subject) == nil
      assert Subject.user_id(%Subject{}) == nil
    end
  end

  describe "in_account?/2 + ensure_in_account/3" do
    test "true / :ok only when the subject's account matches" do
      subject = %Subject{account: %Account{id: "acct-A"}}

      assert Subject.in_account?(subject, "acct-A")
      refute Subject.in_account?(subject, "acct-B")
      # An account-less subject is in no account.
      refute Subject.in_account?(%Subject{}, "acct-A")

      assert Subject.ensure_in_account(subject, "acct-A") == :ok
    end

    test "ensure_in_account defaults to :not_found and accepts a custom error atom" do
      subject = %Subject{account: %Account{id: "acct-A"}}

      assert Subject.ensure_in_account(subject, "acct-B") == {:error, :not_found}

      assert Subject.ensure_in_account(subject, "acct-B", :unauthorized) ==
               {:error, :unauthorized}
    end
  end
end
