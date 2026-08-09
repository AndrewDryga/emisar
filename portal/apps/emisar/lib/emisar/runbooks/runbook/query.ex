defmodule Emisar.Runbooks.Runbook.Query do
  use Emisar, :query
  alias Emisar.Repo.Filter

  def all,
    do: from(runbooks in Emisar.Runbooks.Runbook, as: :runbooks)

  def none(queryable), do: where(queryable, false)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [runbooks: r], is_nil(r.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [runbooks: r], r.id == ^id)

  def by_ids(queryable, ids) when is_list(ids),
    do: where(queryable, [runbooks: r], r.id in ^ids)

  def select_ids(queryable),
    do: select(queryable, [runbooks: r], r.id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runbooks: r], r.account_id == ^account_id)

  # The slug is the runbook's stable public identity: refs depend on it, so it
  # is frozen once a release exists.
  def by_slug(queryable, slug),
    do: where(queryable, [runbooks: r], r.slug == ^slug)

  def live(queryable \\ all()),
    do: where(queryable, [runbooks: r], not is_nil(r.live_version))

  def has_draft(queryable \\ all()),
    do: where(queryable, [runbooks: r], not is_nil(r.draft_definition))

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def ordered_by_title(queryable),
    do: order_by(queryable, [runbooks: r], asc: r.title)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runbooks, :asc, :title}, {:runbooks, :asc, :id}]

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :state,
        title: "State",
        type: {:list, :string},
        values: [{"live", "Live"}, {"draft", "Unpublished changes"}],
        fun: fn queryable, states -> {queryable, state_dynamic(states)} end
      }
    ]

  # A runbook can be live AND carry unpublished changes, so the chosen states
  # are a union rather than a partition. None recognized is "all".
  defp state_dynamic(states) do
    case Enum.filter(states, &(&1 in ["live", "draft"])) do
      [] -> dynamic(true)
      chosen -> Enum.reduce(chosen, dynamic(false), &state_or/2)
    end
  end

  defp state_or("live", acc), do: dynamic([runbooks: r], ^acc or not is_nil(r.live_version))
  defp state_or("draft", acc), do: dynamic([runbooks: r], ^acc or not is_nil(r.draft_definition))

  # Label-batcher for `Audit.resolve_references/1`. The query module
  # already knows the named binding, so audit-side resolution can stay
  # Repo-only without poking at the schema.
  def select_labels(queryable, ids, field) do
    queryable
    |> where([runbooks: r], r.id in ^ids)
    |> select([runbooks: r], {r.id, field(r, ^field)})
  end
end
