defmodule Emisar.MCPOperations.Authorizer do
  @moduledoc "Authorization for bridge mutation identity and recovery."
  use Emisar.Auth.Authorizer
  alias Emisar.MCPOperations.Operation

  def view_operations_permission, do: build(Operation, :view)
  def reserve_operations_permission, do: build(Operation, :reserve)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(:api_client),
    do: [view_operations_permission(), reserve_operations_permission()]

  def list_permissions_for_role(role)
      when role in [:owner, :admin, :operator, :viewer, :runner],
      do: []

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Operation.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _subject), do: queryable
end
