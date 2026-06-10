defmodule Emisar.Runbooks.Runbook.Query do
  use Emisar, :query

  def all,
    do: from(runbooks in Emisar.Runbooks.Runbook, as: :runbooks)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [runbooks: r], is_nil(r.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [runbooks: r], r.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runbooks: r], r.account_id == ^account_id)

  def by_status(queryable, status),
    do: where(queryable, [runbooks: r], r.status == ^status)

  def ordered_by_title_version(queryable),
    do: order_by(queryable, [runbooks: r], asc: r.title, desc: r.version)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runbooks, :asc, :title}, {:runbooks, :desc, :version}, {:runbooks, :asc, :id}]

  # Label-batcher for `Audit.resolve_references/1`. The query module
  # already knows the named binding, so audit-side resolution can stay
  # Repo-only without poking at the schema.
  def select_labels(queryable, ids, field) do
    queryable
    |> where([runbooks: r], r.id in ^ids)
    |> select([runbooks: r], {r.id, field(r, ^field)})
  end
end
