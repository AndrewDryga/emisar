defmodule Emisar.OAuth.Token.Query do
  use Emisar, :query
  alias Emisar.OAuth.Token

  def all, do: from(t in Token, as: :tokens)

  def by_access_hash(queryable \\ all(), hash),
    do: where(queryable, [tokens: t], t.access_token_hash == ^hash)

  def by_refresh_hash(queryable \\ all(), hash),
    do: where(queryable, [tokens: t], t.refresh_token_hash == ^hash)

  def not_revoked(queryable \\ all()), do: where(queryable, [tokens: t], is_nil(t.revoked_at))

  def for_api_key(queryable \\ all(), api_key_id),
    do: where(queryable, [tokens: t], t.api_key_id == ^api_key_id)
end
