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
  Inner-join the membership's (non-deleted) account, idempotently. Use it
  on its own to filter on account columns; pair with a preload via
  `with_preloaded_account/1`. A membership whose account is soft-deleted
  is dropped (inner join to `not_deleted/0`).
  """
  def with_joined_account(queryable) do
    with_named_binding(queryable, :account, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [memberships: m],
        account in ^Emisar.Accounts.Account.Query.not_deleted(),
        on: m.account_id == account.id,
        as: ^binding
      )
    end)
  end

  @doc "Join (if needed) and preload the membership's account. See `with_joined_account/1`."
  def with_preloaded_account(queryable) do
    queryable
    |> with_joined_account()
    |> preload([memberships: m, account: account], account: account)
  end

  @doc "Inner-join the membership's (non-deleted) user, idempotently. See `with_joined_account/1`."
  def with_joined_user(queryable) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [memberships: m],
        user in ^Emisar.Accounts.User.Query.not_deleted(),
        on: m.user_id == user.id,
        as: ^binding
      )
    end)
  end

  @doc "Join (if needed) and preload the membership's user. See `with_joined_account/1`."
  def with_preloaded_user(queryable) do
    queryable
    |> with_joined_user()
    |> preload([memberships: m, user: user], user: user)
  end

  # -- Pagination + preloads -------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:memberships, :desc, :inserted_at}, {:memberships, :asc, :id}]

  # Each preload is `{scope_query, nested_preloads}` so the associated
  # schema's own preloads/0 cascades — deep nesting composes. The scope is
  # not_deleted/0 so a membership never resolves a soft-deleted account/user.
  @impl Emisar.Repo.Query
  def preloads,
    do: [
      account:
        {Emisar.Accounts.Account.Query.not_deleted(), Emisar.Accounts.Account.Query.preloads()},
      user: {Emisar.Accounts.User.Query.not_deleted(), Emisar.Accounts.User.Query.preloads()}
    ]
end
