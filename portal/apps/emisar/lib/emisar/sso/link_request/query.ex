defmodule Emisar.SSO.LinkRequest.Query do
  use Emisar, :query
  alias Emisar.SSO.LinkRequest

  def all,
    do: from(requests in LinkRequest, as: :requests)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [requests: r], r.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [requests: r], r.account_id == ^account_id)

  def by_provider_id(queryable, provider_id),
    do: where(queryable, [requests: r], r.provider_id == ^provider_id)

  def ordered_by_recent(queryable),
    do: order_by(queryable, [requests: r], desc: r.inserted_at, desc: r.id)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:requests, :desc, :inserted_at}, {:requests, :desc, :id}]
end
