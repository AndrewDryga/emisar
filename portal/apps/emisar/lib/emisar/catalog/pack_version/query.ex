defmodule Emisar.Catalog.PackVersion.Query do
  use Emisar, :query

  def all,
    do: from(packs in Emisar.Catalog.PackVersion, as: :packs)

  def by_id(queryable, id),
    do: where(queryable, [packs: p], p.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [packs: p], p.account_id == ^account_id)

  def by_pack_id(queryable, pack_id),
    do: where(queryable, [packs: p], p.pack_id == ^pack_id)

  def by_pack_id_and_version(queryable, pack_id, version) do
    where(queryable, [packs: p], p.pack_id == ^pack_id and p.version == ^version)
  end

  def pending(queryable \\ all()),
    do: where(queryable, [packs: p], p.trust_state == :pending)

  def ordered_by_pack(queryable \\ all()),
    do: order_by(queryable, [packs: p], asc: p.pack_id, asc: p.version)

  @doc """
  Row lock for the trust/reject re-read (`FOR NO KEY UPDATE`) so a
  concurrent Trust and Reject on the same row serialize instead of the
  loser updating a row the winner already flipped or deleted.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:packs, :asc, :pack_id}, {:packs, :asc, :version}, {:packs, :asc, :id}]
end
