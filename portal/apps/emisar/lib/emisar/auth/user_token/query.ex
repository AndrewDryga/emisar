defmodule Emisar.Auth.UserToken.Query do
  use Emisar, :query

  def all,
    do: from(t in Emisar.Auth.UserToken, as: :tokens)

  def by_user_id(q \\ all(), user_id),
    do: where(q, [tokens: t], t.user_id == ^user_id)

  def by_context(q \\ all(), context) when is_binary(context),
    do: where(q, [tokens: t], t.context == ^context)

  def by_contexts(q \\ all(), contexts) when is_list(contexts),
    do: where(q, [tokens: t], t.context in ^contexts)

  def by_id(q \\ all(), id),
    do: where(q, [tokens: t], t.id == ^id)

  def ordered_by_recent(q \\ all()),
    do: order_by(q, [tokens: t], desc: t.inserted_at)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:tokens, :desc, :inserted_at}, {:tokens, :asc, :id}]
end
