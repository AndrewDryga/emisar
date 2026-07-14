defmodule Emisar.MCPOperations.Operation.Query do
  use Emisar, :query

  def all,
    do: from(operations in Emisar.MCPOperations.Operation, as: :mcp_operations)

  def by_account_id(queryable, account_id),
    do: where(queryable, [mcp_operations: o], o.account_id == ^account_id)

  def by_lineage_id(queryable, lineage_id),
    do: where(queryable, [mcp_operations: o], o.credential_lineage_id == ^lineage_id)

  def by_operation_id(queryable, operation_id),
    do: where(queryable, [mcp_operations: o], o.operation_id == ^operation_id)
end
