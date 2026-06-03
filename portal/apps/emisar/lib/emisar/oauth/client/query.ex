defmodule Emisar.OAuth.Client.Query do
  use Emisar, :query
  alias Emisar.OAuth.Client

  def all, do: from(c in Client, as: :clients)

  def by_id(q \\ all(), id), do: where(q, [clients: c], c.id == ^id)
end
