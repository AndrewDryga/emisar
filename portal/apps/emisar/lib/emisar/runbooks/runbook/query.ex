defmodule Emisar.Runbooks.Runbook.Query do
  use Emisar, :query

  def all,
    do: from(runbooks in Emisar.Runbooks.Runbook, as: :runbooks)

  def not_deleted(q \\ all()),
    do: where(q, [runbooks: r], is_nil(r.deleted_at))

  def by_id(q, id),
    do: where(q, [runbooks: r], r.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [runbooks: r], r.account_id == ^account_id)

  def by_status(q, status),
    do: where(q, [runbooks: r], r.status == ^status)

  def ordered_by_title_version(q),
    do: order_by(q, [runbooks: r], asc: r.title, desc: r.version)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runbooks, :asc, :title}, {:runbooks, :desc, :version}, {:runbooks, :asc, :id}]

  # Label-batcher for `Audit.resolve_references/1`. The query module
  # already knows the named binding, so audit-side resolution can stay
  # Repo-only without poking at the schema.
  def select_labels(q, ids, field) do
    q
    |> where([runbooks: r], r.id in ^ids)
    |> select([runbooks: r], {r.id, field(r, ^field)})
  end
end
