defmodule Emisar.Admin.Staff.Query do
  use Emisar, :query
  alias Emisar.Admin.Staff

  def all, do: from(staff in Staff, as: :staff)

  def by_id(queryable \\ all(), id), do: where(queryable, [staff: s], s.id == ^id)

  # `email` is citext, so the database compares case-insensitively.
  def by_email(queryable \\ all(), email) when is_binary(email),
    do: where(queryable, [staff: s], s.email == ^email)

  def ordered_by_email(queryable \\ all()), do: order_by(queryable, [staff: s], asc: s.email)

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  @impl Emisar.Repo.Query
  def preloads, do: []
end
