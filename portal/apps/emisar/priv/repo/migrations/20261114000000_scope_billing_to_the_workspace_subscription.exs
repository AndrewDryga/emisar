defmodule Emisar.Repo.Migrations.ScopeBillingToTheWorkspaceSubscription do
  use Ecto.Migration

  def change do
    # Emisar no longer rewrites a Paddle customer after creating it: the payer
    # owns its email, name and address, so the sync bookkeeping goes.
    alter table(:accounts) do
      remove :paddle_billing_contact_user_id,
             references(:users, type: :binary_id, on_delete: :nilify_all)

      remove :paddle_customer_synced_at, :utc_datetime_usec
    end

    # One pending mailbox proof per workspace for linking an existing Paddle
    # customer, bound to the Member who asked and the address it was sent to.
    create table(:billing_customer_link_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :membership_id, :binary_id, null: false
      add :email, :text, null: false
      add :code_digest, :binary, null: false
      add :remaining_attempts, :integer, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:billing_customer_link_codes, [:account_id])

    # A Paddle subscription belongs to one workspace. Several workspaces can
    # share a customer, so the subscription id is what names the owner.
    drop index(:billing_subscriptions, [:paddle_subscription_id],
           where: "paddle_subscription_id IS NOT NULL",
           name: :billing_subscriptions_paddle_subscription_id_idx
         )

    create unique_index(:billing_subscriptions, [:paddle_subscription_id],
             where: "paddle_subscription_id IS NOT NULL",
             name: :billing_subscriptions_paddle_subscription_id_idx
           )

    execute """
            ALTER TABLE billing_customer_link_codes
            ADD CONSTRAINT billing_customer_link_codes_membership_fkey
            FOREIGN KEY (account_id, membership_id)
            REFERENCES account_memberships (account_id, id) ON DELETE CASCADE
            """,
            """
            ALTER TABLE billing_customer_link_codes
            DROP CONSTRAINT billing_customer_link_codes_membership_fkey
            """
  end
end
