defmodule Emisar.Repo.Migrations.AddPaddleCustomerSyncToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :paddle_billing_contact_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :paddle_customer_synced_at, :utc_datetime_usec
    end

    create index(:accounts, [:paddle_billing_contact_user_id])
  end
end
