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

  describe "for_user/4" do
    setup do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      %{user: user, account: account}
    end

    test "owner gets the full owner-role permission set", %{user: user, account: account} do
      membership = %Membership{role: "owner", user_id: user.id, account_id: account.id}

      subject = Subject.for_user(user, account, membership)

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
      viewer_subj =
        Subject.for_user(user, account, %Membership{
          role: "viewer",
          user_id: user.id,
          account_id: account.id
        })

      admin_subj =
        Subject.for_user(user, account, %Membership{
          role: "admin",
          user_id: user.id,
          account_id: account.id
        })

      # Admin is a strict superset of viewer.
      assert MapSet.subset?(viewer_subj.permissions, admin_subj.permissions)
      assert MapSet.size(viewer_subj.permissions) < MapSet.size(admin_subj.permissions)
    end

    test "unknown role string falls back to viewer (default-deny posture)", %{
      user: user,
      account: account
    } do
      subject =
        Subject.for_user(user, account, %Membership{
          role: "no-such-role",
          user_id: user.id,
          account_id: account.id
        })

      # The fallback is the same shape as an explicit viewer subject —
      # not all-perms, not empty.
      viewer_perms = Emisar.Auth.Permissions.for_role(:viewer)
      assert subject.role == :viewer
      assert subject.permissions == viewer_perms
    end
  end

  describe "Authorizer.permissions_for/1" do
    test "returns an empty set for unknown roles" do
      assert MapSet.size(Emisar.Auth.Permissions.for_role(:nope)) == 0
    end

    test "returns the same set on every call (purity)" do
      assert Emisar.Auth.Permissions.for_role(:owner) ==
               Emisar.Auth.Permissions.for_role(:owner)
    end
  end

  describe "Authorizer.ensure_has_permissions/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      %{account: account, user: user}
    end

    test ":ok when the subject holds the permission", %{account: account, user: user} do
      subject =
        Subject.for_user(user, account, %Membership{
          role: "owner",
          user_id: user.id,
          account_id: account.id
        })

      assert :ok =
               Emisar.Auth.Authorizer.ensure_has_permissions(
                 subject,
                 Emisar.Accounts.Authorizer.manage_security_settings_permission()
               )
    end

    test "{:error, :unauthorized} when the subject lacks it", %{account: account, user: user} do
      subject =
        Subject.for_user(user, account, %Membership{
          role: "viewer",
          user_id: user.id,
          account_id: account.id
        })

      assert {:error, :unauthorized} =
               Emisar.Auth.Authorizer.ensure_has_permissions(
                 subject,
                 Emisar.Accounts.Authorizer.manage_security_settings_permission()
               )
    end

    test "{:one_of, [...]} succeeds if any one permission is held", %{
      account: account,
      user: user
    } do
      operator =
        Subject.for_user(user, account, %Membership{
          role: "operator",
          user_id: user.id,
          account_id: account.id
        })

      # Operator does NOT hold manage_runners but DOES hold view_runners.
      perms = [
        Emisar.Runners.Authorizer.manage_runners_permission(),
        Emisar.Runners.Authorizer.view_runners_permission()
      ]

      assert :ok = Emisar.Auth.Authorizer.ensure_has_permissions(operator, {:one_of, perms})
    end

    test "rejects {:one_of, [...]} if the subject holds none", %{account: account, user: user} do
      viewer =
        Subject.for_user(user, account, %Membership{
          role: "viewer",
          user_id: user.id,
          account_id: account.id
        })

      perms = [
        Emisar.Accounts.Authorizer.manage_security_settings_permission(),
        Emisar.Accounts.Authorizer.manage_team_permission()
      ]

      assert {:error, :unauthorized} =
               Emisar.Auth.Authorizer.ensure_has_permissions(viewer, {:one_of, perms})
    end

    test "a plain list requires ALL permissions — holding every one passes", %{
      account: account,
      user: user
    } do
      owner =
        Subject.for_user(user, account, %Membership{
          role: "owner",
          user_id: user.id,
          account_id: account.id
        })

      # Owner holds both of these.
      perms = [
        Emisar.Accounts.Authorizer.manage_security_settings_permission(),
        Emisar.Accounts.Authorizer.manage_team_permission()
      ]

      assert :ok = Emisar.Auth.Authorizer.ensure_has_permissions(owner, perms)
    end

    test "a plain list is rejected when the subject lacks any one of them", %{
      account: account,
      user: user
    } do
      admin =
        Subject.for_user(user, account, %Membership{
          role: "admin",
          user_id: user.id,
          account_id: account.id
        })

      # Admin holds manage_team but NOT manage_owners (owner-only), so requiring
      # both fails — a permission list requires ALL of them.
      perms = [
        Emisar.Accounts.Authorizer.manage_team_permission(),
        Emisar.Accounts.Authorizer.manage_owners_permission()
      ]

      assert {:error, :unauthorized} =
               Emisar.Auth.Authorizer.ensure_has_permissions(admin, perms)
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
    test "carries the runner role and defaults to an empty request context" do
      account = %Account{id: "acct-1"}
      runner = %Runner{id: "runner-1"}

      subject = Subject.for_runner(runner, account)

      assert subject.role == :runner
      assert subject.actor == runner
      assert subject.account == account
      assert subject.context == %RequestContext{}
      assert subject.permissions == Emisar.Auth.Permissions.for_role(:runner)
    end
  end

  describe "actor_kind/1 + actor_id/1 + actor_email/1" do
    test "classify each actor, with system/nil fallbacks for an actor-less subject" do
      user_subject = %Subject{actor: %User{id: "u1", email: "ops@example.test"}}
      key_subject = %Subject{actor: %ApiKey{id: "k1"}}
      runner_subject = %Subject{actor: %Runner{id: "r1"}}
      actorless = %Subject{}

      assert Subject.actor_kind(user_subject) == "user"
      assert Subject.actor_kind(key_subject) == "api_key"
      assert Subject.actor_kind(runner_subject) == "runner"
      assert Subject.actor_kind(actorless) == "system"

      assert Subject.actor_id(user_subject) == "u1"
      assert Subject.actor_id(key_subject) == "k1"
      assert Subject.actor_id(actorless) == nil

      assert Subject.actor_email(user_subject) == "ops@example.test"
      # Only a user actor has an email — keys, runners, and the actor-less
      # subject return nil (this feeds the Paddle buyer-email attach).
      assert Subject.actor_email(key_subject) == nil
      assert Subject.actor_email(actorless) == nil
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

      assert :ok = Subject.ensure_in_account(subject, "acct-A")
    end

    test "ensure_in_account defaults to :not_found and accepts a custom error atom" do
      subject = %Subject{account: %Account{id: "acct-A"}}

      assert {:error, :not_found} = Subject.ensure_in_account(subject, "acct-B")

      assert {:error, :unauthorized} =
               Subject.ensure_in_account(subject, "acct-B", :unauthorized)
    end
  end
end
