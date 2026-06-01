defmodule Emisar.Accounts.Membership.Query do
  use Emisar, :query

  def all,
    do: from(memberships in Emisar.Accounts.Membership, as: :memberships)

  def not_deleted(q \\ all()),
    do: where(q, [memberships: m], is_nil(m.deleted_at))

  def not_disabled(q \\ all()),
    do: where(q, [memberships: m], is_nil(m.disabled_at))

  def by_id(q, id),
    do: where(q, [memberships: m], m.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [memberships: m], m.account_id == ^account_id)

  def by_user_id(q, user_id),
    do: where(q, [memberships: m], m.user_id == ^user_id)

  def by_role(q, role),
    do: where(q, [memberships: m], m.role == ^role)

  def by_roles(q, roles) when is_list(roles),
    do: where(q, [memberships: m], m.role in ^roles)

  def by_account_and_user(q, account_id, user_id) do
    q
    |> where([memberships: m], m.account_id == ^account_id and m.user_id == ^user_id)
  end

  def by_invitation_token(q, token),
    do: where(q, [memberships: m], m.invitation_token == ^token)

  def pending_invitation(q),
    do: where(q, [memberships: m], is_nil(m.invitation_accepted_at))

  def ordered_by_recent(q),
    do: order_by(q, [memberships: m], desc: m.inserted_at)

  def latest(q), do: limit(q, 1)

  @doc """
  Restrict to memberships whose account is not soft-deleted. Used by
  the account picker so a user can't pick a tenant that's been
  deleted out from under them.
  """
  def for_active_account(q) do
    q
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
