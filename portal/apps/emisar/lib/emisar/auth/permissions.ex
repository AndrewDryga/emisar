defmodule Emisar.Auth.Permissions do
  @moduledoc """
  The permission catalogue: unions every context authorizer's
  `list_permissions_for_role/1` into the permission set a `%Subject{}`
  carries, and answers role-coverage questions derived from it.

  Lives OUTSIDE `Emisar.Auth.Authorizer` on purpose: every context
  authorizer compile-depends on that module via `use`, so the core a
  module `use`s should not also hold a registry of its own users — the
  mutual reference put the auth core and all ten authorizers in one
  xref cycle. (Measured note: Elixir's checksum + exports-aware
  compiler already kept body-edit recompile fanout at 1 file, so the
  split is about ownership, not build time — editing the auth core
  still rebuilds the authorizers, the irreducible `use` cost.)
  """
  alias Emisar.Auth.Subject

  @authorizers [
    Emisar.Accounts.Authorizer,
    Emisar.ApiKeys.Authorizer,
    Emisar.Approvals.Authorizer,
    Emisar.Audit.Authorizer,
    Emisar.Billing.Authorizer,
    Emisar.Catalog.Authorizer,
    Emisar.Policies.Authorizer,
    Emisar.Runbooks.Authorizer,
    Emisar.Runs.Authorizer,
    Emisar.Runners.Authorizer
  ]

  @doc """
  Returns the full permission set for a role. Unions every authorizer's
  `list_permissions_for_role/1`; unknown roles get an empty set.
  """
  def for_role(role) when is_atom(role) do
    @authorizers
    |> Enum.flat_map(& &1.list_permissions_for_role(role))
    |> MapSet.new()
  end

  def for_role(_), do: MapSet.new()

  @doc """
  True when the subject already holds EVERY permission `role` grants.
  This is the no-escalation primitive behind role changes/invites and
  role-name guards like "only an owner can manage owners": no role
  hierarchy, just `for_role(role) ⊆ subject.permissions`. Robust to a
  non-nested permission model in a way a `== :owner` check is not.
  """
  def covers_role?(%Subject{permissions: permissions}, role),
    do: MapSet.subset?(for_role(role), permissions)

  @doc """
  The membership roles whose permission set includes `permission` — e.g.
  the roles that can decide approvals. Derived from `for_role/1`, so an
  eligibility/recipient list built from it can't drift from the
  role → permission source of truth (unlike a hard-coded `[:owner,
  :admin]`).
  """
  def roles_with_permission(permission),
    do: Enum.filter(Emisar.Auth.Role.all(), &MapSet.member?(for_role(&1), permission))
end
