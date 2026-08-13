defmodule Emisar.Catalog.PackVersion.Query do
  use Emisar, :query

  def all,
    do: from(packs in Emisar.Catalog.PackVersion, as: :packs)

  def none(queryable), do: where(queryable, false)

  def by_id(queryable, id),
    do: where(queryable, [packs: p], p.id == ^id)

  def by_ids(queryable, ids),
    do: where(queryable, [packs: p], p.id in ^ids)

  def by_account_id(queryable, account_id),
    do: where(queryable, [packs: p], p.account_id == ^account_id)

  def by_pack_id(queryable, pack_id),
    do: where(queryable, [packs: p], p.pack_id == ^pack_id)

  def distinct_pack_ids(queryable),
    do: queryable |> distinct(true) |> select([packs: p], p.pack_id)

  def by_pack_id_and_version(queryable, pack_id, version) do
    where(queryable, [packs: p], p.pack_id == ^pack_id and p.version == ^version)
  end

  def by_pack_refs(queryable, []), do: none(queryable)

  def by_pack_refs(queryable, pack_refs) when is_list(pack_refs) do
    predicate =
      Enum.reduce(pack_refs, dynamic(false), fn {pack_id, version}, predicate ->
        dynamic(
          [packs: pack],
          ^predicate or (pack.pack_id == ^pack_id and pack.version == ^version)
        )
      end)

    where(queryable, ^predicate)
  end

  def by_deployments(queryable, []), do: none(queryable)

  def by_deployments(queryable, deployments) when is_list(deployments) do
    predicate =
      Enum.reduce(deployments, dynamic(false), fn {pack_id, version, hash}, predicate ->
        dynamic(
          [packs: p],
          ^predicate or
            (p.pack_id == ^pack_id and p.version == ^version and
               fragment("coalesce(?, ?)", p.pending_hash, p.hash) == ^hash)
        )
      end)

    where(queryable, ^predicate)
  end

  def pending(queryable \\ all()),
    do: where(queryable, [packs: p], p.trust_state == :pending)

  @doc "Trusted rows with no retirement override — the retired-blocked badge read."
  def trusted_unoverridden(queryable \\ all()) do
    where(
      queryable,
      [packs: p],
      p.trust_state == :trusted and is_nil(p.retirement_overridden_at)
    )
  end

  @doc """
  Load only the columns a retirement decision turns on. The verdict needs a
  baseline comparison this query can't express, so the rows still come back —
  but every console page's nav badge counts them, and the full row carries the
  pack's whole trusted manifest.
  """
  def select_decision_fields(queryable) do
    select(
      queryable,
      [packs: p],
      struct(p, [:id, :trust_state, :retirement_overridden_at, :pack_id, :version])
    )
  end

  @doc """
  Load every column except `trusted_manifest` — the console's browse read. The
  manifest is a complete per-version descriptor snapshot (the table's heaviest
  column) that only a pending review's diff consumes; the console re-reads
  those few rows whole by id.
  """
  def select_without_manifest(queryable) do
    fields = Emisar.Catalog.PackVersion.__schema__(:fields) -- [:trusted_manifest]
    select(queryable, [packs: p], struct(p, ^fields))
  end

  def by_pack_ids(queryable \\ all(), pack_ids),
    do: where(queryable, [packs: p], p.pack_id in ^pack_ids)

  def by_versions(queryable \\ all(), versions),
    do: where(queryable, [packs: p], p.version in ^versions)

  def last_seen_before(queryable \\ all(), cutoff),
    do: where(queryable, [packs: p], p.last_seen_at < ^cutoff)

  def ordered_by_pack(queryable \\ all()),
    do: order_by(queryable, [packs: p], asc: p.pack_id, asc: p.version)

  @doc "Audit label-lookup helper for pack-version targets."
  def select_audit_labels(queryable, ids) do
    queryable
    |> where([packs: p], p.id in ^ids)
    |> select([packs: p], {p.id, p.pack_id, p.version})
  end

  def limit_to(queryable, limit), do: limit(queryable, ^limit)

  @doc """
  Row lock for the trust/reject re-read (`FOR NO KEY UPDATE`) so a
  concurrent Trust and Reject on the same row serialize instead of the
  loser updating a row the winner already flipped or deleted.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  @doc """
  Left-join the row's (non-deleted) retirement-override user, idempotently —
  the admin who re-trusted a retired version. LEFT, not inner: almost every
  row has no override, and they must not be dropped from the list.
  """
  def with_joined_retirement_overridden_by(queryable) do
    with_named_binding(queryable, :retirement_overridden_by, fn queryable, binding ->
      join(
        queryable,
        :left,
        [packs: p],
        user in ^Emisar.Users.User.Query.not_deleted(),
        on: p.retirement_overridden_by_id == user.id,
        as: ^binding
      )
    end)
  end

  @doc "Join (if needed) and preload the retirement-override user. See `with_joined_retirement_overridden_by/1`."
  def with_preloaded_retirement_overridden_by(queryable) do
    queryable
    |> with_joined_retirement_overridden_by()
    |> preload([packs: p, retirement_overridden_by: user], retirement_overridden_by: user)
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:packs, :asc, :pack_id}, {:packs, :asc, :version}, {:packs, :asc, :id}]
end
