defmodule Emisar.OAuth.Token.Query do
  use Emisar, :query
  alias Emisar.OAuth.Token

  def all, do: from(t in Token, as: :tokens)

  def by_access_hash(q \\ all(), hash), do: where(q, [tokens: t], t.access_token_hash == ^hash)
  def by_refresh_hash(q \\ all(), hash), do: where(q, [tokens: t], t.refresh_token_hash == ^hash)

  def not_revoked(q \\ all()), do: where(q, [tokens: t], is_nil(t.revoked_at))

  def for_api_key(q \\ all(), api_key_id),
    do: where(q, [tokens: t], t.api_key_id == ^api_key_id)
end
