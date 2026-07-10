defmodule Emisar.Runbooks.Runbook.Query do
  use Emisar, :query
  alias Emisar.Repo.Filter

  def all,
    do: from(runbooks in Emisar.Runbooks.Runbook, as: :runbooks)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [runbooks: r], is_nil(r.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [runbooks: r], r.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runbooks: r], r.account_id == ^account_id)

  # All versions of one runbook share a slug within an account — deleting a
  # runbook (as opposed to publishing one version) spans the whole family.
  def by_slug(queryable, slug),
    do: where(queryable, [runbooks: r], r.slug == ^slug)

  def published(queryable \\ all()),
    do: where(queryable, [runbooks: r], r.status == :published)

  def ordered_by_title_version(queryable),
    do: order_by(queryable, [runbooks: r], asc: r.title, desc: r.version)

  # The single highest-version row of whatever it's chained onto — a slug's
  # versions share the slug, so this picks the newest one. Owns both its order
  # and its limit, so a caller can't take the ordering without the cap.
  def latest_version(queryable),
    do: queryable |> order_by([runbooks: r], desc: r.version) |> limit(1)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runbooks, :asc, :title}, {:runbooks, :desc, :version}, {:runbooks, :asc, :id}]

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :status,
        title: "Status",
        type: {:list, :string},
        values: [{"published", "Published"}, {"draft", "Draft"}],
        fun: fn queryable, statuses -> {queryable, status_dynamic(statuses)} end
      }
    ]

  # The multi-select sends the chosen status strings; map them to the enum
  # atoms through a whitelist (never String.to_atom on request input — IL-14).
  # None / both selected is "all".
  defp status_dynamic(statuses) do
    case Enum.flat_map(statuses, &status_atom/1) do
      [] -> dynamic(true)
      atoms -> dynamic([runbooks: r], r.status in ^atoms)
    end
  end

  defp status_atom("published"), do: [:published]
  defp status_atom("draft"), do: [:draft]
  defp status_atom(_), do: []

  # Label-batcher for `Audit.resolve_references/1`. The query module
  # already knows the named binding, so audit-side resolution can stay
  # Repo-only without poking at the schema.
  def select_labels(queryable, ids, field) do
    queryable
    |> where([runbooks: r], r.id in ^ids)
    |> select([runbooks: r], {r.id, field(r, ^field)})
  end
end
