defmodule Emisar.Billing.CheckoutIntent do
  use Emisar, :schema

  schema "billing_checkout_intents" do
    field :account_id, :binary_id
    field :plan, Ecto.Enum, values: [:team]
    field :billing_interval, Ecto.Enum, values: [:month, :year]
    field :customer_id, :string
    field :price_id, :string
    field :quantity, :integer

    field :transaction_id, :string
    field :checkout_url, :string

    field :state, Ecto.Enum,
      values: [
        :creating,
        :binding,
        :payable,
        :retiring_transaction,
        :payment_reconciling,
        :subscribed,
        :canceled,
        :failed
      ]

    field :failure_category, Ecto.Enum,
      values: [
        :provider_unavailable,
        :invalid_provider_data,
        :ambiguous_create,
        :persistence_failed
      ]

    timestamps()
  end
end
