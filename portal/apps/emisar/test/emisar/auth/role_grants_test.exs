defmodule Emisar.Auth.RoleGrantsTest do
  @moduledoc """
  The exact permission set each role grants, pinned.

  `Emisar.Auth.Permissions.for_role/1` unions every context Authorizer's
  `list_permissions_for_role/1`, so a permission added to one authorizer changes
  what a role can do across the whole product. Nothing asserted the RESULT: the
  existing subject tests compare `subject.permissions` to `for_role(...)` — the
  function that built them — which proves the right role was selected but not
  what that role holds, and one of them compared `for_role(:owner)` to itself.

  So adding a permission to `:viewer` failed no test. These goldens make that a
  deliberate, reviewed diff instead. Update them in the same change that changes
  a grant, and read the diff as the security review it is.
  """
  use ExUnit.Case, async: true
  alias Emisar.Auth.Permissions
  alias Emisar.Auth.Role

  @owner [
    {Emisar.Accounts.Account, :manage_own},
    {Emisar.Accounts.Account, :manage_security},
    {Emisar.Accounts.Account, :view_own},
    {Emisar.Accounts.Membership, :invite},
    {Emisar.Accounts.Membership, :manage_owners},
    {Emisar.Accounts.Membership, :manage_team},
    {Emisar.ApiKeys.ApiKey, :issue_quick},
    {Emisar.ApiKeys.ApiKey, :manage},
    {Emisar.ApiKeys.ApiKey, :view},
    {Emisar.Approvals.Grant, :manage},
    {Emisar.Approvals.Request, :decide},
    {Emisar.Approvals.Request, :view},
    {Emisar.Audit.Event, :view},
    {Emisar.Billing.Subscription, :manage},
    {Emisar.Billing.Subscription, :view},
    {Emisar.Billing.Subscription, :view_invoices},
    {Emisar.Catalog.PackVersion, :manage},
    {Emisar.Catalog.RunnerAction, :view},
    {Emisar.Policies.Policy, :manage},
    {Emisar.Policies.Policy, :view},
    {Emisar.Runbooks.Runbook, :manage},
    {Emisar.Runbooks.Runbook, :author},
    {Emisar.Runbooks.Runbook, :view},
    {Emisar.Runners.EnrollmentKey, :issue_install},
    {Emisar.Runners.EnrollmentKey, :manage},
    {Emisar.Runners.Runner, :manage},
    {Emisar.Runners.Runner, :view},
    {Emisar.Runs.ActionRun, :cancel},
    {Emisar.Runs.ActionRun, :dispatch},
    {Emisar.Runs.ActionRun, :view},
    {Emisar.SSO.IdentityProvider, :manage},
    {Emisar.SSO.IdentityProvider, :view_posture},
    {Emisar.Users.User, :edit_self}
  ]

  # admin is owner minus the two owner-only grants.
  @admin @owner --
           [
             {Emisar.Accounts.Membership, :manage_owners},
             {Emisar.Billing.Subscription, :manage}
           ]

  @billing_manager [
    {Emisar.Accounts.Account, :view_own},
    {Emisar.Billing.Subscription, :manage},
    {Emisar.Billing.Subscription, :view},
    {Emisar.Billing.Subscription, :view_invoices},
    {Emisar.SSO.IdentityProvider, :view_posture},
    {Emisar.Users.User, :edit_self}
  ]

  @operator [
    {Emisar.Accounts.Account, :view_own},
    {Emisar.ApiKeys.ApiKey, :issue_quick},
    {Emisar.ApiKeys.ApiKey, :view},
    {Emisar.Approvals.Request, :decide},
    {Emisar.Approvals.Request, :view},
    {Emisar.Audit.Event, :view},
    {Emisar.Billing.Subscription, :view},
    {Emisar.Catalog.RunnerAction, :view},
    {Emisar.Policies.Policy, :view},
    {Emisar.Runbooks.Runbook, :author},
    {Emisar.Runbooks.Runbook, :view},
    {Emisar.Runners.EnrollmentKey, :issue_install},
    {Emisar.Runners.Runner, :view},
    {Emisar.Runs.ActionRun, :cancel},
    {Emisar.Runs.ActionRun, :dispatch},
    {Emisar.Runs.ActionRun, :view},
    {Emisar.SSO.IdentityProvider, :view_posture},
    {Emisar.Users.User, :edit_self}
  ]

  @viewer [
    {Emisar.Accounts.Account, :view_own},
    {Emisar.ApiKeys.ApiKey, :view},
    {Emisar.Approvals.Request, :view},
    {Emisar.Audit.Event, :view},
    {Emisar.Billing.Subscription, :view},
    {Emisar.Catalog.RunnerAction, :view},
    {Emisar.Policies.Policy, :view},
    {Emisar.Runbooks.Runbook, :view},
    {Emisar.Runners.Runner, :view},
    {Emisar.Runs.ActionRun, :view},
    {Emisar.SSO.IdentityProvider, :view_posture},
    {Emisar.Users.User, :edit_self}
  ]

  # Not a membership role: the credential an LLM client authenticates with.
  @api_client [
    {Emisar.Accounts.Account, :view_own},
    {Emisar.Audit.Event, :view},
    {Emisar.Catalog.RunnerAction, :view},
    {Emisar.MCPOperations.Operation, :reserve},
    {Emisar.MCPOperations.Operation, :view},
    {Emisar.Runbooks.Runbook, :draft},
    {Emisar.Runbooks.Runbook, :view},
    {Emisar.Runners.Runner, :view},
    {Emisar.Runs.ActionRun, :dispatch},
    {Emisar.Runs.ActionRun, :view}
  ]

  # The runner reads its own catalog and its own runs. Nothing else.
  @runner [
    {Emisar.Catalog.RunnerAction, :view},
    {Emisar.Runs.ActionRun, :view}
  ]

  @goldens %{
    owner: @owner,
    admin: @admin,
    billing_manager: @billing_manager,
    operator: @operator,
    viewer: @viewer,
    api_client: @api_client,
    runner: @runner
  }

  describe "for_role/1 grants exactly" do
    for {role, expected} <- @goldens do
      test "#{role}" do
        assert Permissions.for_role(unquote(role)) == MapSet.new(unquote(Macro.escape(expected)))
      end
    end
  end

  test "an unknown role grants nothing" do
    assert Permissions.for_role(:nope) == MapSet.new([])
  end

  # A role added to Emisar.Auth.Role without a golden would otherwise ship
  # unpinned, which is the gap these goldens exist to close.
  test "every membership role is pinned above" do
    assert Enum.sort(Role.all()) == Enum.sort(Map.keys(@goldens) -- [:api_client, :runner])
  end

  describe "the privilege ordering the escalation guards rely on" do
    test "admin is owner minus manage_owners and billing management" do
      assert MapSet.difference(Permissions.for_role(:owner), Permissions.for_role(:admin)) ==
               MapSet.new([
                 {Emisar.Accounts.Membership, :manage_owners},
                 {Emisar.Billing.Subscription, :manage}
               ])
    end

    test "viewer holds no permission an operator lacks" do
      assert MapSet.subset?(Permissions.for_role(:viewer), Permissions.for_role(:operator))
    end

    test "operator holds no permission an admin lacks" do
      assert MapSet.subset?(Permissions.for_role(:operator), Permissions.for_role(:admin))
    end

    test "the runner credential holds strictly less than any human role" do
      assert MapSet.subset?(Permissions.for_role(:runner), Permissions.for_role(:viewer))
    end
  end
end
