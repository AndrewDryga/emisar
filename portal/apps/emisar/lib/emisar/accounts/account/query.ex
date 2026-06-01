defmodule Emisar.Accounts.Account.Query do
  use Emisar, :query

  def all,
    do: from(accounts in Emisar.Accounts.Account, as: :accounts)

  def not_deleted(q \\ all()),
    do: where(q, [accounts: a], is_nil(a.deleted_at))

  def by_id(q, id),
    do: where(q, [accounts: a], a.id == ^id)

  def by_slug(q, slug),
    do: where(q, [accounts: a], a.slug == ^slug)

  def by_paddle_customer_id(q, cid),
    do: where(q, [accounts: a], a.paddle_customer_id == ^cid)

  def ordered_by_name(q),
    do: order_by(q, [accounts: a], asc: a.name)

  @doc """
  Restrict to accounts the given user is a (non-suspended) member of.
  Used by the "switch account" picker — a suspended user is not shown
  as a member of the tenant that suspended them.
  """
  def with_active_member(q, user_id) do
    q
    |> join(:inner, [accounts: a], m in Emisar.Accounts.Membership,
      on: m.account_id == a.id,
      as: :memberships
    )
    |> where([memberships: m], m.user_id == ^user_id and is_nil(m.disabled_at))
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:accounts, :asc, :name}, {:accounts, :asc, :id}]
end
