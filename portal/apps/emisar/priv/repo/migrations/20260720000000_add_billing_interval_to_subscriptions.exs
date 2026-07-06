defmodule Emisar.Repo.Migrations.AddBillingIntervalToSubscriptions do
  use Ecto.Migration

  # The subscription's billing cadence, mirrored from the Paddle
  # subscription item's `price.billing_cycle.interval` ("month" | "year").
  # Nullable: pre-annual rows and monthly subscriptions read as monthly.
  def change do
    alter table(:subscriptions) do
      add :billing_interval, :string
    end
  end
end
