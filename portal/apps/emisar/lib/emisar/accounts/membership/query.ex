defmodule Emisar.Accounts.Membership.Query do
  use Emisar, :query

  def all,
    do: from(memberships in Emisar.Accounts.Membership, as: :memberships)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [memberships: m], is_nil(m.deleted_at))

  def not_disabled(queryable \\ all()),
    do: where(queryable, [memberships: m], is_nil(m.disabled_at))

  def by_id(queryable, id),
    do: where(queryable, [memberships: m], m.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [memberships: m], m.account_id == ^account_id)

  def by_user_id(queryable, user_id),
    do: where(queryable, [memberships: m], m.user_id == ^user_id)

  def by_role(queryable, role),
    do: where(queryable, [memberships: m], m.role == ^role)

  def by_roles(queryable, roles) when is_list(roles),
    do: where(queryable, [memberships: m], m.role in ^roles)

  def by_account_and_user(queryable, account_id, user_id) do
    queryable
    |> where([memberships: m], m.account_id == ^account_id and m.user_id == ^user_id)
  end

  def by_invitation_token(queryable, token),
    do: where(queryable, [memberships: m], m.invitation_token == ^token)

  def pending_invitation(queryable),
    do: where(queryable, [memberships: m], is_nil(m.invitation_accepted_at))

  def ordered_by_recent(queryable),
    do: order_by(queryable, [memberships: m], desc: m.inserted_at)

  def latest(queryable), do: limit(queryable, 1)

  @doc """
  Restrict to memberships whose account is not soft-deleted. Used by
  the account picker so a user can't pick a tenant that's been
  deleted out from under them.
  """
  def for_active_account(queryable) do
    queryable
    |> join(:inner, [memberships: m], a in Emisar.Accounts.Account,
      on: a.id == m.account_id,
      as: :accounts
    )
    |> where([accounts: a], is_nil(a.deleted_at))
  end

  # -- Pagination + preloads -------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:memberships, :desc, :inserted_at}, {:memberships, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads,
    do: [account: [], user: []]
end
