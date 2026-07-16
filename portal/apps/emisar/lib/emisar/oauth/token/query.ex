defmodule Emisar.OAuth.Token.Query do
  use Emisar, :query
  alias Emisar.OAuth.Token

  def all, do: from(tokens in Token, as: :tokens)

  def by_access_hash(queryable \\ all(), hash),
    do: where(queryable, [tokens: t], t.access_token_hash == ^hash)

  def by_refresh_hash(queryable \\ all(), hash),
    do: where(queryable, [tokens: t], t.refresh_token_hash == ^hash)

  def not_revoked(queryable \\ all()), do: where(queryable, [tokens: t], is_nil(t.revoked_at))

  @doc """
  OAuth token pairs that can no longer be used or refreshed. A pair with a
  refresh token stays until that longer-lived grant expires; access-only rows
  are eligible once their access token expires.
  """
  def expired_before(queryable \\ all(), now) do
    where(
      queryable,
      [tokens: t],
      t.access_expires_at < ^now and
        (is_nil(t.refresh_expires_at) or t.refresh_expires_at < ^now)
    )
  end

  @doc """
  Row lock for the refresh-rotation re-read (`FOR NO KEY UPDATE`) so two
  concurrent refreshes of the same token serialize — the loser sees the
  winner's revocation instead of both rotating and minting two pairs.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")
end
