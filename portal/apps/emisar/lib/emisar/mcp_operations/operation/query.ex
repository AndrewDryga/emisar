defmodule Emisar.MCPOperations.Operation.Query do
  use Emisar, :query

  def all,
    do: from(operations in Emisar.MCPOperations.Operation, as: :mcp_operations)

  def by_ids(queryable \\ all(), ids) when is_list(ids),
    do: where(queryable, [mcp_operations: o], o.id in ^ids)

  def by_account_id(queryable, account_id),
    do: where(queryable, [mcp_operations: o], o.account_id == ^account_id)

  def by_lineage_id(queryable, lineage_id),
    do: where(queryable, [mcp_operations: o], o.credential_lineage_id == ^lineage_id)

  def by_operation_id(queryable, operation_id),
    do: where(queryable, [mcp_operations: o], o.operation_id == ^operation_id)

  def inserted_before(queryable, %DateTime{} = cutoff),
    do: where(queryable, [mcp_operations: o], o.inserted_at < ^cutoff)

  @doc "A bounded page of operation ids older than the replay window cutoff."
  def prunable_ids(%DateTime{} = cutoff, limit) when is_integer(limit) do
    all()
    |> inserted_before(cutoff)
    |> limit(^limit)
    |> select([mcp_operations: o], o.id)
  end
end
