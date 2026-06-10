defmodule Emisar.Auth.UserToken.Query do
  use Emisar, :query

  def all,
    do: from(t in Emisar.Auth.UserToken, as: :tokens)

  def by_user_id(queryable \\ all(), user_id),
    do: where(queryable, [tokens: t], t.user_id == ^user_id)

  def by_context(queryable \\ all(), context) when is_binary(context),
    do: where(queryable, [tokens: t], t.context == ^context)

  def by_contexts(queryable \\ all(), contexts) when is_list(contexts),
    do: where(queryable, [tokens: t], t.context in ^contexts)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [tokens: t], t.id == ^id)

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [tokens: t], desc: t.inserted_at)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:tokens, :desc, :inserted_at}, {:tokens, :asc, :id}]
end
