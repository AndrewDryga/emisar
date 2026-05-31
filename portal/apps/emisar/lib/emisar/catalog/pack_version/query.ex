defmodule Emisar.Catalog.PackVersion.Query do
  use Emisar, :query

  def all,
    do: from(packs in Emisar.Catalog.PackVersion, as: :packs)

  def by_id(q, id),
    do: where(q, [packs: p], p.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [packs: p], p.account_id == ^account_id)

  def by_pack_id(q, pack_id),
    do: where(q, [packs: p], p.pack_id == ^pack_id)

  def ordered_by_pack(q \\ all()),
    do: order_by(q, [packs: p], asc: p.pack_id, asc: p.version)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:packs, :asc, :pack_id}, {:packs, :asc, :version}, {:packs, :asc, :id}]
end
