defmodule Emisar.Runbooks.Release.Query do
  use Emisar, :query

  def all,
    do: from(runbook_releases in Emisar.Runbooks.Release, as: :runbook_releases)

  def by_runbook_id(queryable \\ all(), runbook_id),
    do: where(queryable, [runbook_releases: r], r.runbook_id == ^runbook_id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [runbook_releases: r], r.account_id == ^account_id)
end
