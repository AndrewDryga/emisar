defmodule Emisar.Auth.UserToken.Query do
  use Emisar, :query
  alias Emisar.Auth.UserToken

  # Validity windows. These can move to runtime config later; defaults
  # err on the side of "short enough not to be the weakest link if a
  # phone is lost."
  @session_validity_in_days 60
  @confirm_validity_in_days 7
  @magic_link_validity_in_minutes 15
  @email_change_validity_in_minutes 15

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

  @doc "Split-code magic-link tokens that still have guess attempts left (locked at 0)."
  def with_attempts_remaining(queryable),
    do: where(queryable, [tokens: t], t.remaining_attempts > 0)

  @doc "Only rows whose auth_method is a currently-valid enum value — a session holding a removed value (a legacy :password session) is excluded rather than raising ArgumentError on load, so it fails closed to not-found instead of 500ing the auth path."
  def with_valid_auth_method(queryable \\ all()) do
    valid = Ecto.Enum.values(UserToken, :auth_method)
    where(queryable, [tokens: t], t.auth_method in ^valid)
  end

  defp validity_in_days("session"), do: @session_validity_in_days
  defp validity_in_days("confirm"), do: @confirm_validity_in_days
  defp validity_in_days("magic_link"), do: @magic_link_validity_in_minutes / (24 * 60)
  defp validity_in_days("email_change"), do: @email_change_validity_in_minutes / (24 * 60)

  @doc ~S(Preload the token's user, scoped to live users — a soft-deleted user's token preloads no user.)
  def with_preloaded_user(queryable \\ all()) do
    preload(queryable, user: ^Emisar.Users.User.Query.not_deleted())
  end

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [tokens: t], desc: t.inserted_at)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:tokens, :desc, :inserted_at}, {:tokens, :asc, :id}]
end
