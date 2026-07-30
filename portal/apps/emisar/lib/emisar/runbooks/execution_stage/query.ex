defmodule Emisar.Runbooks.ExecutionStage.Query do
  use Emisar, :query

  def all,
    do: from(stages in Emisar.Runbooks.ExecutionStage, as: :runbook_execution_stages)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [runbook_execution_stages: s], s.id == ^id)

  def by_execution_id(queryable \\ all(), execution_id),
    do: where(queryable, [runbook_execution_stages: s], s.runbook_execution_id == ^execution_id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [runbook_execution_stages: s], s.account_id == ^account_id)

  def by_status(queryable \\ all(), status),
    do: where(queryable, [runbook_execution_stages: s], s.status == ^status)

  def ordered(queryable \\ all()),
    do: order_by(queryable, [runbook_execution_stages: s], asc: s.position)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")
end
