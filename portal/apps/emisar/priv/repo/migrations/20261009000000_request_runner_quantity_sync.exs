defmodule Emisar.Repo.Migrations.RequestRunnerQuantitySync do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:billing_subscriptions) do
      add :runner_quantity_sync_requested_at, :utc_datetime_usec
    end

    create index(:billing_subscriptions, [:id],
             where: "runner_quantity_sync_requested_at IS NOT NULL",
             name: :billing_subscriptions_runner_quantity_sync_queue_index,
             concurrently: true
           )
  end
end
