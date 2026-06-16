defmodule Emisar.CapabilitiesTest do
  @moduledoc """
  The full capability matrix: every context's `subject_can_<verb>?/1`
  predicate asserted against every membership role. Widening or narrowing a
  role's permissions fails CI here immediately — the same guarantee the old
  EmisarWeb.Permissions matrix gave, now in the domain where the predicates
  live.
  """
  use ExUnit.Case, async: true

  alias Emisar.Auth.{Authorizer, Subject}

  alias Emisar.{Accounts, ApiKeys, Approvals, Billing, Catalog}
  alias Emisar.{Policies, Runbooks, Runners, Runs}

  @roles [:owner, :admin, :operator, :viewer]

  defp subject(role), do: %Subject{permissions: Emisar.Auth.Permissions.for_role(role)}

  test "subject_can_<verb>? predicates match the role matrix" do
    matrix = [
      {&Billing.subject_can_manage_billing?/1, [:owner]},
      {&Accounts.subject_can_manage_account_security?/1, [:owner]},
      {&Accounts.subject_can_manage_team?/1, [:owner, :admin]},
      {&Runners.subject_can_manage_runners?/1, [:owner, :admin]},
      {&Runners.subject_can_manage_auth_keys?/1, [:owner, :admin]},
      {&ApiKeys.subject_can_manage_api_keys?/1, [:owner, :admin]},
      {&Policies.subject_can_manage_policies?/1, [:owner, :admin]},
      {&Runbooks.subject_can_manage_runbooks?/1, [:owner, :admin]},
      {&Catalog.subject_can_manage_packs?/1, [:owner, :admin]},
      {&Runs.subject_can_dispatch_run?/1, [:owner, :admin, :operator]},
      {&Runs.subject_can_cancel_run?/1, [:owner, :admin, :operator]},
      {&Approvals.subject_can_decide_approval?/1, [:owner, :admin, :operator]}
    ]

    for {predicate, allowed} <- matrix, role <- @roles do
      expected = role in allowed

      assert predicate.(subject(role)) == expected,
             "expected #{inspect(predicate)} for role #{role} to be #{expected}"
    end
  end
end
