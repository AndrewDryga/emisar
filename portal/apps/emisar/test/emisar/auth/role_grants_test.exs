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
    {Emisar.Approvals.Request, :override},
    {Emisar.Approvals.Request, :view},
    {Emisar.Audit.Event, :view},
    {Emisar.Audit.Event, :view_billing},
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

  # admin is owner minus the one owner-only grant.
  @admin @owner -- [{Emisar.Accounts.Membership, :manage_owners}]

  @billing_manager [
    {Emisar.Accounts.Account, :view_own},
    {Emisar.Audit.Event, :view_billing},
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
    {Emisar.Audit.Event, :view_billing},
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
    {Emisar.Audit.Event, :view_billing},
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
    {Emisar.Audit.Event, :view_billing},
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

  # The three permissions a machine credential holds that no human role does.
  # Every function they gate matches `%Subject{actor: %ApiKeys.ApiKey{}}` in its
  # HEAD — `MCPOperations.reserve_in_multi/3`, `fetch_recovery/2`,
  # `resource_id/3`, and the `Runbooks.create_or_replay_mcp_*` family — so a
  # human subject falls to the `{:error, :unauthorized}` clause before the
  # permission is ever consulted; granting them to an owner would unlock
  # nothing. `:api_client` is not an assignable role either (`Auth.Role.all/0`
  # and the `Membership` enum both exclude it), so no delegation guard ever asks
  # whether an owner covers it.
  @machine_only [
    {Emisar.MCPOperations.Operation, :reserve},
    {Emisar.MCPOperations.Operation, :view},
    {Emisar.Runbooks.Runbook, :draft}
  ]

  # Deliberate deviations from "owner and admin can do anything any role can".
  # Owner's list is EMPTY for every membership role — that is the invariant with
  # no exception, and it is what keeps an owner able to GRANT every role:
  # `covers_role?/2` is a plain subset test with no notion of one permission
  # implying another, so a permission handed to one narrow role would otherwise
  # silently strand it. Each entry below is held by an OWNER, so nothing is
  # closed to owner and admin together.
  @sanctioned_gaps %{
    # Appointing an owner is the ONE thing an admin cannot do; that gap IS the
    # ownership boundary. Since admins hold `manage_billing`, `:billing_manager`
    # has no entry here at all — an admin covers the finance seat entirely, and
    # `covers_role?/2` therefore lets an admin appoint it.
    {:admin, :owner} => [{Emisar.Accounts.Membership, :manage_owners}],
    {:owner, :api_client} => @machine_only,
    {:admin, :api_client} => @machine_only
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

  # The durable half of the goldens: a permission added to ONE narrow role has
  # to reach owner and admin too, or this fails. The assertion is an equality on
  # the gap, so deleting a sanctioned exception is as visible a diff as adding
  # one — granting an admin `manage_billing` is what removed the whole
  # {:admin, :billing_manager} entry, and this test is what demanded it.
  describe "owner and admin cover every role" do
    for superset <- [:owner, :admin], {role, _grants} <- @goldens, role != superset do
      test "#{superset} holds every permission #{role} does" do
        gap =
          MapSet.difference(
            Permissions.for_role(unquote(role)),
            Permissions.for_role(unquote(superset))
          )

        assert gap ==
                 MapSet.new(Map.get(@sanctioned_gaps, {unquote(superset), unquote(role)}, []))
      end
    end
  end

  describe "the privilege ordering the escalation guards rely on" do
    test "viewer holds no permission an operator lacks" do
      assert MapSet.subset?(Permissions.for_role(:viewer), Permissions.for_role(:operator))
    end

    test "the runner credential holds strictly less than any human role" do
      assert MapSet.subset?(Permissions.for_role(:runner), Permissions.for_role(:viewer))
    end
  end
end
