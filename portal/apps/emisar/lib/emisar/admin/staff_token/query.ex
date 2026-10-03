defmodule Emisar.Admin.StaffToken.Query do
  use Emisar, :query
  alias Emisar.Admin.{Staff, StaffToken}

  def all, do: from(tokens in StaffToken, as: :staff_tokens)

  def by_id(queryable \\ all(), id), do: where(queryable, [staff_tokens: t], t.id == ^id)

  def by_staff_id(queryable \\ all(), staff_id),
    do: where(queryable, [staff_tokens: t], t.staff_id == ^staff_id)

  def by_context(queryable \\ all(), context) when context in [:sign_in, :session],
    do: where(queryable, [staff_tokens: t], t.context == ^context)

  def by_token_digest(queryable \\ all(), digest) when is_binary(digest),
    do: where(queryable, [staff_tokens: t], t.token == ^digest)

  # The database clock decides, like the workspace session predicate, so every
  # node agrees on the instant a token stops counting.
  def not_expired(queryable \\ all()),
    do: where(queryable, [staff_tokens: t], t.expires_at > from_now(0, "second"))

  def expired(queryable \\ all()),
    do: where(queryable, [staff_tokens: t], t.expires_at <= from_now(0, "second"))

  @doc "Loads the staff login with the token, in the same query."
  def with_preloaded_staff(queryable) do
    queryable
    |> join(:inner, [staff_tokens: t], staff in assoc(t, :staff), as: :staff)
    |> preload([staff_tokens: t, staff: staff], staff: staff)
  end

  @doc "Stored digests, for a DELETE RETURNING that names the sockets to disconnect."
  def select_token_digests(queryable), do: select(queryable, [staff_tokens: t], t.token)

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  @impl Emisar.Repo.Query
  def preloads, do: [staff: {Staff.Query.all(), Staff.Query.preloads()}]
end
