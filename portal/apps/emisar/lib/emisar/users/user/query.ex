defmodule Emisar.Users.User.Query do
  use Emisar, :query

  def all,
    do: from(users in Emisar.Users.User, as: :users)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [users: u], is_nil(u.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [users: u], u.id == ^id)

  def by_ids(queryable, ids),
    do: where(queryable, [users: u], u.id in ^ids)

  def by_email(queryable, email),
    do: where(queryable, [users: u], u.email == ^String.downcase(email))

  @doc """
  `Audit.resolve_references/1` helper — narrow to ids, project
  `{id, label_field}` tuples. Plain SQL composition for label lookup
  fan-out; not paginated.
  """
  def select_labels(queryable, ids, field) do
    queryable
    |> where([users: u], u.id in ^ids)
    |> select([users: u], {u.id, field(u, ^field)})
  end

  @doc """
  Restrict to users who are members of `account_id`. Users aren't
  account-scoped by a column (they belong to accounts via memberships),
  so audit label resolution joins through membership: a user referenced
  on an account's audit row is a member of that account, so correctly-
  stamped ids still resolve while a mis-stamped id from another account
  is filtered out (defense-in-depth). `distinct` guards against a user
  with several memberships in the same account (none today) duplicating.
  """
  def members_of_account(queryable, account_id) do
    queryable
    |> join(:inner, [users: u], m in Emisar.Accounts.Membership,
      on: m.user_id == u.id,
      as: :memberships
    )
    |> where([memberships: m], m.account_id == ^account_id)
    |> distinct([users: u], u.id)
  end

  # No nested preloads cascade when a user is loaded through the Preloader;
  # declared so callers can compose `{not_deleted(), preloads()}`.
  @impl Emisar.Repo.Query
  def preloads, do: []
end
