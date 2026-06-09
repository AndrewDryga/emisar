defmodule Emisar.Accounts.User.Query do
  use Emisar, :query

  def all,
    do: from(users in Emisar.Accounts.User, as: :users)

  def not_deleted(q \\ all()),
    do: where(q, [users: u], is_nil(u.deleted_at))

  def by_id(q, id),
    do: where(q, [users: u], u.id == ^id)

  def by_ids(q, ids),
    do: where(q, [users: u], u.id in ^ids)

  def by_email(q, email),
    do: where(q, [users: u], u.email == ^String.downcase(email))

  @doc """
  `Audit.resolve_references/1` helper — narrow to ids, project
  `{id, label_field}` tuples. Plain SQL composition for label lookup
  fan-out; not paginated.
  """
  def select_labels(q, ids, field) do
    q
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
  def members_of_account(q, account_id) do
    q
    |> join(:inner, [users: u], m in Emisar.Accounts.Membership,
      on: m.user_id == u.id,
      as: :memberships
    )
    |> where([memberships: m], m.account_id == ^account_id)
    |> distinct([users: u], u.id)
  end
end
