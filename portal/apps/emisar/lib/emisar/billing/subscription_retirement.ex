defmodule Emisar.Billing.SubscriptionRetirement do
  use Emisar, :schema

  schema "billing_subscription_retirements" do
    field :account_id, :binary_id
    field :customer_id, :string
    field :transaction_id, :string
    field :subscription_id, :string
    field :canonical_subscription_id, :string

    field :reason, Ecto.Enum, values: [:duplicate, :account_closed, :account_erased]
    field :state, Ecto.Enum, values: [:pending, :confirmed]
    field :failure_category, Ecto.Enum, values: [:provider_unavailable, :invalid_provider_data]
    field :confirmed_at, :utc_datetime_usec

    timestamps()
  end
end
