defmodule Emisar.Auth.PermissionsTest do
  @moduledoc """
  The permission catalogue's derived queries: `covers_role?/2` (the
  no-escalation primitive behind role changes/invites) and
  `roles_with_permission/1` (which roles can do a thing — the approval
  recipient/eligibility source of truth). Both are pure derivations of
  `for_role/1`, so they can't drift from the role → permission model.
  """
  use ExUnit.Case, async: true

  alias Emisar.Accounts
  alias Emisar.Auth.Permissions
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks

  describe "for_role/1" do
    test "non-atom input falls through to the empty set (defensive)" do
      assert MapSet.equal?(Permissions.for_role("owner"), MapSet.new())
      assert MapSet.equal?(Permissions.for_role(nil), MapSet.new())
    end
  end

  describe "covers_role?/2" do
    test "an owner subject covers every membership role" do
      owner = %Subject{permissions: Permissions.for_role(:owner)}

      for role <- [:owner, :admin, :operator, :viewer] do
        assert Permissions.covers_role?(owner, role)
      end
    end

    test "a viewer covers itself but not a higher-privileged role" do
      viewer = %Subject{permissions: Permissions.for_role(:viewer)}

      assert Permissions.covers_role?(viewer, :viewer)
      refute Permissions.covers_role?(viewer, :admin)
      refute Permissions.covers_role?(viewer, :owner)
    end

    test "any subject vacuously covers a role that grants no permissions" do
      # for_role(:nonexistent) is the empty set, and ∅ ⊆ anything.
      empty = %Subject{permissions: MapSet.new()}
      assert Permissions.covers_role?(empty, :nonexistent)
    end
  end

  describe "roles_with_permission/1" do
    test "an owner-only permission resolves to exactly [:owner]" do
      assert Permissions.roles_with_permission(
               Accounts.Authorizer.manage_security_settings_permission()
             ) == [:owner]
    end

    test "a permission no role grants resolves to []" do
      assert Permissions.roles_with_permission({Accounts.Account, :no_such_action}) == []
    end

    test "every role that can manage runbooks can also view them" do
      manage_roles =
        Permissions.roles_with_permission(Runbooks.Authorizer.manage_runbooks_permission())

      view_roles =
        Permissions.roles_with_permission(Runbooks.Authorizer.view_runbooks_permission())

      assert :owner in manage_roles
      refute :viewer in manage_roles
      assert :viewer in view_roles
      assert MapSet.subset?(MapSet.new(manage_roles), MapSet.new(view_roles))
    end
  end
end
