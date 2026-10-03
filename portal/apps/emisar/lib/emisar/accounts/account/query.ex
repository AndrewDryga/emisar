defmodule Emisar.Accounts.Account.Query do
  use Emisar, :query

  def all,
    do: from(accounts in Emisar.Accounts.Account, as: :accounts)

  def none(queryable), do: where(queryable, false)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [accounts: a], is_nil(a.deleted_at))

  def active(queryable \\ not_deleted()),
    do: where(queryable, [accounts: a], is_nil(a.disabled_at))

  def by_id(queryable, id),
    do: where(queryable, [accounts: a], a.id == ^id)

  def by_ids(queryable, ids) when is_list(ids),
    do: where(queryable, [accounts: a], a.id in ^ids)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  # Keyset paging by id (UUIDv7, time-ordered) — system sweep account
  # cursor: order by id, take a page, continue past the last id.
  def after_id(queryable, id),
    do: where(queryable, [accounts: a], a.id > ^id)

  def by_slug(queryable, slug),
    do: where(queryable, [accounts: a], a.slug == ^slug)

  def by_paddle_customer_id(queryable, customer_id),
    do: where(queryable, [accounts: a], a.paddle_customer_id == ^customer_id)

  def ordered_by_name(queryable),
    do: order_by(queryable, [accounts: a], asc: a.name)

  def ordered_by_id(queryable),
    do: order_by(queryable, [accounts: a], asc: a.id)

  def limit_to(queryable, n) when is_integer(n) and n > 0,
    do: limit(queryable, ^n)

  @doc """
  Accounts whose monthly value report is due at `cutoff` (start of the current
  month): never sent, or last sent in an earlier month. Pairs with the report
  job's per-month cadence.
  """
  def due_for_report(queryable, %DateTime{} = cutoff) do
    where(
      queryable,
      [accounts: a],
      is_nil(a.last_report_sent_at) or a.last_report_sent_at < ^cutoff
    )
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:accounts, :asc, :name}, {:accounts, :asc, :id}]

  # No nested preloads cascade when an account is loaded through the
  # Preloader; declared so callers can compose `{not_deleted(), preloads()}`.
  @impl Emisar.Repo.Query
  def preloads, do: []
end
