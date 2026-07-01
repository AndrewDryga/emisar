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

  # Join (if needed) + preload the request's account — the pending-approval page
  # shows the org name the person is waiting to join.
  def with_joined_account(queryable) do
    with_named_binding(queryable, :account, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [requests: r],
        account in ^Emisar.Accounts.Account.Query.not_deleted(),
        on: r.account_id == account.id,
        as: ^binding
      )
    end)
  end

  def with_preloaded_account(queryable) do
    queryable
    |> with_joined_account()
    |> preload([requests: r, account: account], account: account)
  end

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:requests, :desc, :inserted_at}, {:requests, :desc, :id}]
end
