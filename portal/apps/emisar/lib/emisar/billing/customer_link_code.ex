defmodule Emisar.Billing.CustomerLinkCode do
  @moduledoc """
  A pending mailbox proof for linking a workspace to an existing Paddle
  customer: one per account, bound to the Member who asked and the address the
  code went to. Only the code's digest is stored.
  """
  use Emisar, :schema

  schema "billing_customer_link_codes" do
    field :account_id, :binary_id
    field :membership_id, :binary_id
    field :email, :string
    field :code_digest, :binary, redact: true
    field :remaining_attempts, :integer
    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
