defmodule Emisar.Repo.Migrations.AddRecurringPriceFactsToSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :unit_price_amount, :bigint
      add :currency_code, :string
      add :billing_frequency, :integer
    end
  end
end
