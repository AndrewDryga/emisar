defmodule Emisar.Repo.Migrations.TrackCheckoutAndSubscriptionRecovery do
  use Ecto.Migration

  def change do
    create table(:billing_checkout_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Cleanup must survive physical account erasure, retaining only opaque facts.
      add :account_id, :binary_id, null: false
      add :plan, :string, null: false
      add :billing_interval, :string, null: false
      add :customer_id, :string, null: false
      add :price_id, :string, null: false
      add :quantity, :integer, null: false
      add :transaction_id, :string
      add :checkout_url, :text
      add :state, :string, null: false
      add :failure_category, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:billing_checkout_intents, [:account_id],
             where: "state NOT IN ('subscribed', 'canceled', 'failed')",
             name: :billing_checkout_intents_current_account_index
           )

    create unique_index(:billing_checkout_intents, [:transaction_id])
    create index(:billing_checkout_intents, [:account_id, :id])

    create index(:billing_checkout_intents, [:id],
             where: "state NOT IN ('subscribed', 'canceled', 'failed')",
             name: :billing_checkout_intents_pending_index
           )

    create constraint(:billing_checkout_intents, :billing_checkout_intents_shape,
             check: """
             quantity > 0 AND plan = 'team' AND billing_interval IN ('month', 'year')
             AND state IN ('creating', 'binding', 'payable', 'retiring_transaction',
                           'payment_reconciling', 'subscribed', 'canceled', 'failed')
             AND ((state IN ('creating', 'failed') AND transaction_id IS NULL)
                  OR (state NOT IN ('creating', 'failed') AND transaction_id IS NOT NULL))
             AND (state <> 'payable' OR checkout_url IS NOT NULL)
             """
           )

    create table(:billing_subscription_retirements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :customer_id, :string, null: false
      add :transaction_id, :string, null: false
      add :subscription_id, :string, null: false
      add :canonical_subscription_id, :string
      add :reason, :string, null: false
      add :state, :string, null: false
      add :failure_category, :string
      add :confirmed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:billing_subscription_retirements, [:subscription_id])
    create index(:billing_subscription_retirements, [:account_id, :id])

    create index(:billing_subscription_retirements, [:id],
             where: "state = 'pending'",
             name: :billing_subscription_retirements_pending_index
           )

    create constraint(:billing_subscription_retirements, :billing_subscription_retirements_shape,
             check: """
             reason IN ('duplicate', 'account_closed', 'account_erased')
             AND ((state = 'pending' AND confirmed_at IS NULL)
                  OR (state = 'confirmed' AND confirmed_at IS NOT NULL))
             """
           )
  end
end
