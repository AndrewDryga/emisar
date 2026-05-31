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
  `Audit.resolve_references/2` helper — narrow to ids, project
  `{id, label_field}` tuples. Plain SQL composition for label lookup
  fan-out; not paginated.
  """
  def select_labels(q, ids, field) do
    q
    |> where([users: u], u.id in ^ids)
    |> select([users: u], {u.id, field(u, ^field)})
  end
end
