defmodule Emisar.OAuth.AuthorizationCode.Query do
  use Emisar, :query
  alias Emisar.OAuth.AuthorizationCode

  def all, do: from(c in AuthorizationCode, as: :codes)

  def by_code_hash(queryable \\ all(), hash),
    do: where(queryable, [codes: c], c.code_hash == ^hash)

  def expired_before(queryable \\ all(), now),
    do: where(queryable, [codes: c], c.expires_at < ^now)

  def never_used(queryable \\ all()),
    do: where(queryable, [codes: c], is_nil(c.used_at))

  @doc "Selects each matched code's backing api_key id — the OAuth cleanup's abandoned-key lookup."
  def select_api_key_ids(queryable),
    do: select(queryable, [codes: c], c.api_key_id)

  # Lock the matched row FOR UPDATE so two concurrent token exchanges of the
  # same code serialize: the first burns it (sets used_at) and commits, the
  # second blocks then sees it used and is rejected. Single-use is an
  # OAuth 2.1 MUST; without the lock both could pass the used_at check.
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
