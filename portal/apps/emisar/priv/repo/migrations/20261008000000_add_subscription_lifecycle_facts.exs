defmodule Emisar.Repo.Migrations.AddSubscriptionLifecycleFacts do
  use Ecto.Migration

  def change do
    alter table(:billing_subscriptions) do
      add :collection_mode, :string
      add :scheduled_change_action, :string
      add :scheduled_change_effective_at, :utc_datetime_usec
      add :paddle_event_occurred_at, :utc_datetime_usec
    end
  end
end
