defmodule Emisar.Billing.CustomerLinkCode.Query do
  use Emisar, :query
  alias Emisar.Billing.CustomerLinkCode

  def all, do: from(codes in CustomerLinkCode, as: :customer_link_codes)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [customer_link_codes: c], c.account_id == ^account_id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
