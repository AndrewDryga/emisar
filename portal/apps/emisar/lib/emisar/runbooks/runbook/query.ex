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

  def by_account_id(queryable, account_id),
    do: where(queryable, [runbooks: r], r.account_id == ^account_id)

  # All versions of one runbook share a slug within an account — deleting a
  # runbook (as opposed to publishing one version) spans the whole family.
  def by_slug(queryable, slug),
    do: where(queryable, [runbooks: r], r.slug == ^slug)

  def by_slugs(queryable, slugs),
    do: where(queryable, [runbooks: r], r.slug in ^slugs)

  def by_version(queryable, version),
    do: where(queryable, [runbooks: r], r.version == ^version)

  def published(queryable \\ all()),
    do: where(queryable, [runbooks: r], r.status == :published)

  def draft(queryable \\ all()),
    do: where(queryable, [runbooks: r], r.status == :draft)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def ordered_by_title_version(queryable),
    do: order_by(queryable, [runbooks: r], asc: r.title, desc: r.version)

  # The single highest-version row of whatever it's chained onto — a slug's
  # versions share the slug, so this picks the newest one. Owns both its order
  # and its limit, so a caller can't take the ordering without the cap.
  def latest_version(queryable),
    do: queryable |> order_by([runbooks: r], desc: r.version) |> limit(1)

  # One row per slug family: keeps a row only when NO newer non-deleted version
  # of its (account, slug) exists. Stays a plain runbooks queryable, so cursor
  # pagination, filters, and the count aggregate all compose onto it — filters
  # chained after it therefore judge the family's newest version.
  def latest_version_per_slug(queryable) do
    newer_version =
      from(newer in Emisar.Runbooks.Runbook,
        where:
          newer.account_id == parent_as(:runbooks).account_id and
            newer.slug == parent_as(:runbooks).slug and
            is_nil(newer.deleted_at) and
            newer.version > parent_as(:runbooks).version,
        select: 1
      )

    where(queryable, [runbooks: _], not exists(newer_version))
  end

  # One full row per slug — the newest version of whatever the chain narrowed
  # to (e.g. `published()` → the newest published version). DISTINCT ON pins
  # its own leading ORDER BY, so never put this under cursor pagination; it's
  # for bounded `Repo.all` batches.
  def distinct_latest_per_slug(queryable) do
    queryable
    |> distinct([runbooks: r], r.slug)
    |> order_by([runbooks: r], desc: r.version)
  end

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
