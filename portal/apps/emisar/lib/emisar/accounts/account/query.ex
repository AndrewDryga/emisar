defmodule Emisar.Accounts.Account.Query do
  use Emisar, :query

  def all,
    do: from(accounts in Emisar.Accounts.Account, as: :accounts)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [accounts: a], is_nil(a.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [accounts: a], a.id == ^id)

  def by_slug(queryable, slug),
    do: where(queryable, [accounts: a], a.slug == ^slug)

  def by_paddle_customer_id(queryable, cid),
    do: where(queryable, [accounts: a], a.paddle_customer_id == ^cid)

  def ordered_by_name(queryable),
    do: order_by(queryable, [accounts: a], asc: a.name)

  @doc """
  Restrict to accounts the given user is a member of — joins through
  membership on `membership.user_id` and excludes suspended memberships
  (`disabled_at`). Used by the "switch account" picker, so a suspended user
  isn't shown the tenant that suspended them. The join composes
  `Membership.Query.not_deleted/0` so a tombstoned membership can't
  resurface an account either.
  """
  def by_membership_user_id(queryable, user_id) do
    queryable
    |> join(:inner, [accounts: a], m in ^Emisar.Accounts.Membership.Query.not_deleted(),
      on: m.account_id == a.id,
      as: :memberships
    )
    |> where([memberships: m], m.user_id == ^user_id and is_nil(m.disabled_at))
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
