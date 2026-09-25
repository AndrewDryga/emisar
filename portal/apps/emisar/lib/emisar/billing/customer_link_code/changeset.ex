defmodule Emisar.Billing.CustomerLinkCode.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.CustomerLinkCode

  @fields ~w[account_id membership_id email code_digest remaining_attempts expires_at]a

  def issue(attrs) do
    %CustomerLinkCode{}
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:remaining_attempts, greater_than: 0)
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:membership_id, name: :billing_customer_link_codes_membership_fkey)
  end

  def spend_attempt(%CustomerLinkCode{remaining_attempts: remaining} = code),
    do: change(code, remaining_attempts: remaining - 1)
end
