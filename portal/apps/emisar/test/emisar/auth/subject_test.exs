defmodule Emisar.Auth.SubjectTest do
  @moduledoc """
  Foundational invariants for `Auth.Subject` — how role + actor kind
  shape the permission set, and that constructors never crash on the
  bootstrap-time edge cases (system subject, missing account).
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Accounts.Membership
  alias Emisar.Auth.Subject

  describe "for_user/4" do
    test "owner gets the full owner-role permission set" do
      user = user_fixture()
      account = account_fixture()
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

    test "viewer holds strictly fewer permissions than admin" do
      user = user_fixture()
      account = account_fixture()

      viewer_subj =
        Subject.for_user(user, account, %Membership{role: "viewer", user_id: user.id, account_id: account.id})

      admin_subj =
        Subject.for_user(user, account, %Membership{role: "admin", user_id: user.id, account_id: account.id})

      # Admin is a strict superset of viewer.
      assert MapSet.subset?(viewer_subj.permissions, admin_subj.permissions)
      assert MapSet.size(viewer_subj.permissions) < MapSet.size(admin_subj.permissions)
    end

    test "unknown role string falls back to viewer (default-deny posture)" do
      user = user_fixture()
      account = account_fixture()

      subject =
        Subject.for_user(user, account, %Membership{
          role: "no-such-role",
          user_id: user.id,
          account_id: account.id
        })

      # The fallback is the same shape as an explicit viewer subject —
      # not all-perms, not empty.
      viewer_perms = Emisar.Auth.Authorizer.permissions_for(:viewer)
      assert subject.role == :viewer
      assert subject.permissions == viewer_perms
    end
  end

  describe "system/1" do
    test "holds the union of every role's permissions" do
      subject = Subject.system()
      assert subject.actor == :system
      assert subject.role == :system
      assert subject.account == nil

      # A system subject must include any permission an owner has.
      assert MapSet.subset?(
               Emisar.Auth.Authorizer.permissions_for(:owner),
               subject.permissions
             )
    end

    test "with an account attaches the account but keeps :system role" do
      account = account_fixture()
      subject = Subject.system(account)
      assert subject.account == account
      assert subject.role == :system
    end
  end

  describe "Authorizer.permissions_for/1" do
    test "returns an empty set for unknown roles" do
      assert MapSet.size(Emisar.Auth.Authorizer.permissions_for(:nope)) == 0
    end

    test "returns the same set on every call (purity)" do
      assert Emisar.Auth.Authorizer.permissions_for(:owner) ==
               Emisar.Auth.Authorizer.permissions_for(:owner)
    end
  end

  describe "Authorizer.ensure_has_permissions/2" do
    test ":ok when the subject holds the permission" do
      account = account_fixture()
      user = user_fixture()

      subject =
        Subject.for_user(user, account, %Membership{role: "owner", user_id: user.id, account_id: account.id})

      assert :ok =
               Emisar.Auth.Authorizer.ensure_has_permissions(
                 subject,
                 Emisar.Accounts.Authorizer.manage_security_settings_permission()
               )
    end

    test "{:error, :unauthorized} when the subject lacks it" do
      account = account_fixture()
      user = user_fixture()

      subject =
        Subject.for_user(user, account, %Membership{role: "viewer", user_id: user.id, account_id: account.id})

      assert {:error, :unauthorized} =
               Emisar.Auth.Authorizer.ensure_has_permissions(
                 subject,
                 Emisar.Accounts.Authorizer.manage_security_settings_permission()
               )
    end

    test "{:one_of, [...]} succeeds if any one permission is held" do
      account = account_fixture()
      user = user_fixture()

      operator =
        Subject.for_user(user, account, %Membership{role: "operator", user_id: user.id, account_id: account.id})

      # Operator does NOT hold manage_runners but DOES hold view_runners.
      perms = [
        Emisar.Runners.Authorizer.manage_runners_permission(),
        Emisar.Runners.Authorizer.view_runners_permission()
      ]

      assert :ok = Emisar.Auth.Authorizer.ensure_has_permissions(operator, {:one_of, perms})
    end

    test "rejects {:one_of, [...]} if the subject holds none" do
      account = account_fixture()
      user = user_fixture()

      viewer =
        Subject.for_user(user, account, %Membership{role: "viewer", user_id: user.id, account_id: account.id})

      perms = [
        Emisar.Accounts.Authorizer.manage_security_settings_permission(),
        Emisar.Accounts.Authorizer.manage_team_permission()
      ]

      assert {:error, :unauthorized} =
               Emisar.Auth.Authorizer.ensure_has_permissions(viewer, {:one_of, perms})
    end
  end
end
