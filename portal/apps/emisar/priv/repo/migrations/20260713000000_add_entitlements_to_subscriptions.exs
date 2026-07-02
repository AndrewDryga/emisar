defmodule Emisar.Repo.Migrations.AddEntitlementsToSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :entitlements, :map, null: false, default: %{}
    end
  end
end
