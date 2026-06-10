defmodule Emisar.Auth.UserToken.Query do
  use Emisar, :query
  alias Emisar.Auth.UserToken

  # Validity windows. These can move to runtime config later; defaults
  # err on the side of "short enough not to be the weakest link if a
  # phone is lost."
  @session_validity_in_days 60
  @confirm_validity_in_days 7
  @reset_validity_in_days 1
  @magic_link_validity_in_minutes 15

  def all,
    do: from(t in UserToken, as: :tokens)

  def by_user_id(queryable \\ all(), user_id),
    do: where(queryable, [tokens: t], t.user_id == ^user_id)

  def by_context(queryable \\ all(), context) when is_binary(context),
    do: where(queryable, [tokens: t], t.context == ^context)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [tokens: t], t.id == ^id)

  def by_token_digest(queryable \\ all(), digest) when is_binary(digest),
    do: where(queryable, [tokens: t], t.token == ^digest)

  @doc ~S(Every row except the one carrying `digest` — "sign out everywhere else".)
  def except_token_digest(queryable, digest) when is_binary(digest),
    do: where(queryable, [tokens: t], t.token != ^digest)

  @doc "Rows still inside `context`'s validity window."
  def not_expired(queryable, context),
    do: where(queryable, [tokens: t], t.inserted_at > ago(^validity_in_days(context), "day"))

  defp validity_in_days("session"), do: @session_validity_in_days
  defp validity_in_days("confirm"), do: @confirm_validity_in_days
  defp validity_in_days("reset_password"), do: @reset_validity_in_days
  defp validity_in_days("magic_link"), do: @magic_link_validity_in_minutes / (24 * 60)

  def with_joined_user(queryable \\ all()) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [tokens: t],
        user in ^Emisar.Users.User.Query.not_deleted(),
        on: t.user_id == user.id,
        as: ^binding
      )
    end)
  end

  def select_user(queryable),
    do: select(queryable, [user: u], u)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [tokens: t], desc: t.inserted_at)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:tokens, :desc, :inserted_at}, {:tokens, :asc, :id}]
end
