defmodule Emisar.Auth.Permissions do
  @moduledoc """
  The permission catalogue: unions every context authorizer's
  `list_permissions_for_role/1` into the permission set a `%Subject{}`
  carries, and answers role-coverage questions derived from it.

  Lives OUTSIDE `Emisar.Auth.Authorizer` on purpose: every context
  authorizer compile-depends on that module via `use`, so the core a
  module `use`s should not also hold a registry of its own users — the
  mutual reference put the auth core and all twelve authorizers in one
  xref cycle. (Measured note: Elixir's checksum + exports-aware
  compiler already kept body-edit recompile fanout at 1 file, so the
  split is about ownership, not build time — editing the auth core
  still rebuilds the authorizers, the irreducible `use` cost.)
  """
  alias Emisar.Auth.Subject

  @authorizer_contexts ~w(
    Accounts
    ApiKeys
    Approvals
    Audit
    Billing
    Catalog
    MCPOperations
    Policies
    Runbooks
    Runs
    Runners
    SSO
  )

  @doc """
  Returns the full permission set for a role. Unions every authorizer's
  `list_permissions_for_role/1`; unknown roles get an empty set.
  """
  def for_role(role) when is_atom(role) do
    @authorizer_contexts
    |> Enum.flat_map(&authorizer_permissions(&1, role))
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
  Whether `approver_role` covers `target_role`, judged role-to-role rather than
  through a `%Subject{}`. For a decision that must use a role read fresh under
  lock: the subject's permissions are a snapshot from when the session was built,
  so an approver demoted since then still covers what they used to.
  """
  def role_covers_role?(approver_role, target_role),
    do: MapSet.subset?(for_role(target_role), for_role(approver_role))

  @doc """
  The membership roles whose permission set includes `permission` — e.g.
  the roles that can decide approvals. Derived from `for_role/1`, so an
  eligibility/recipient list built from it can't drift from the
  role → permission source of truth (unlike a hard-coded `[:owner,
  :admin]`).
  """
  def roles_with_permission(permission),
    do: Enum.filter(Emisar.Auth.Role.all(), &MapSet.member?(for_role(&1), permission))

  # Keep the fixed registry as names so Permissions does not compile-depend on
  # every authorizer and close a cycle through the shared Auth core.
  defp authorizer_permissions(context, role) do
    authorizer = Module.safe_concat(["Emisar", context, "Authorizer"])
    authorizer.list_permissions_for_role(role)
  end
end
