defmodule Emisar.OAuth.AuthorizationCode.Query do
  use Emisar, :query
  alias Emisar.OAuth.AuthorizationCode

  def all, do: from(c in AuthorizationCode, as: :codes)

  def by_code_hash(q \\ all(), hash), do: where(q, [codes: c], c.code_hash == ^hash)
end
