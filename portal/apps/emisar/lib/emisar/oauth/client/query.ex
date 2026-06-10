defmodule Emisar.OAuth.Client.Query do
  use Emisar, :query
  alias Emisar.OAuth.Client

  def all, do: from(c in Client, as: :clients)

  def by_id(queryable \\ all(), id), do: where(queryable, [clients: c], c.id == ^id)
end
