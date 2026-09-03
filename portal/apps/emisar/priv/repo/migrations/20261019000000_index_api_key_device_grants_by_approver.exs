defmodule Emisar.Repo.Migrations.IndexApiKeyDeviceGrantsByApprover do
  use Ecto.Migration

  def change do
    create index(:api_key_device_grants, [:approved_by_membership_id])
  end
end
