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

  def by_account_and_user(queryable, account_id, user_id) do
    queryable
    |> where([memberships: m], m.account_id == ^account_id and m.user_id == ^user_id)
  end

  def by_invitation_token(queryable, token),
    do: where(queryable, [memberships: m], m.invitation_token == ^token)

  def pending_invitation(queryable),
    do: where(queryable, [memberships: m], is_nil(m.invitation_accepted_at))

  @doc "Most-recently-joined membership only — orders and limits in one step."
  def latest(queryable),
    do: queryable |> order_by([memberships: m], desc: m.inserted_at) |> limit(1)

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

  @doc """
  Inner-join and preload the membership's (non-deleted) account in the
  same query, so a list is fetched in one shot. Idempotent via
  `with_named_binding/3`; a membership whose account is soft-deleted is
  dropped (inner join to `not_deleted/0`).
  """
  def with_preloaded_account(queryable) do
    with_named_binding(queryable, :account, fn queryable, binding ->
      queryable
      |> join(:inner, [memberships: m], account in ^Emisar.Accounts.Account.Query.not_deleted(),
        on: m.account_id == account.id,
        as: ^binding
      )
      |> preload([memberships: m, account: account], account: account)
    end)
  end

  @doc "Inner-join and preload the membership's (non-deleted) user. See `with_preloaded_account/1`."
  def with_preloaded_user(queryable) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      queryable
      |> join(:inner, [memberships: m], user in ^Emisar.Accounts.User.Query.not_deleted(),
        on: m.user_id == user.id,
        as: ^binding
      )
      |> preload([memberships: m, user: user], user: user)
    end)
  end

  # -- Pagination + preloads -------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:memberships, :desc, :inserted_at}, {:memberships, :asc, :id}]

  # Explicit not_deleted preload queries so a membership never resolves a
  # soft-deleted account or user.
  @impl Emisar.Repo.Query
  def preloads,
    do: [
      account: Emisar.Accounts.Account.Query.not_deleted(),
      user: Emisar.Accounts.User.Query.not_deleted()
    ]
end
