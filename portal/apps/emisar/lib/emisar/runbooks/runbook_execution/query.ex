defmodule Emisar.Runbooks.RunbookExecution.Query do
  use Emisar, :query

  def all,
    do: from(runbook_executions in Emisar.Runbooks.RunbookExecution, as: :runbook_executions)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [runbook_executions: r], r.id == ^id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [runbook_executions: r], r.account_id == ^account_id)

  def active(queryable \\ all()),
    do: where(queryable, [runbook_executions: r], r.status == :active)
end
