defmodule Emisar.MCPOperations.Authorizer do
  @moduledoc "Authorization for bridge mutation identity and recovery."
  use Emisar.Auth.Authorizer
  alias Emisar.MCPOperations.Operation

  def view_operations_permission, do: build(Operation, :view)
  def reserve_operations_permission, do: build(Operation, :reserve)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(:api_client),
    do: [view_operations_permission(), reserve_operations_permission()]

  # The only two permissions in the product an owner deliberately does NOT hold.
  # An operation is one MCP client's idempotency ledger entry, keyed to the
  # calling key's credential lineage: every function they gate matches
  # `%Subject{actor: %ApiKeys.ApiKey{}}` in its HEAD, so a human subject is
  # refused by the clause before the permission is read. Granting them here
  # would unlock nothing and imply a console surface that does not exist —
  # an owner reads what a model DID through the audit trail and the run record.
  # Pinned as a sanctioned exception in `Emisar.Auth.RoleGrantsTest`.
  def list_permissions_for_role(role)
      when role in [:owner, :admin, :operator, :viewer],
      do: []

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Operation.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: Operation.Query.none(queryable)
end
