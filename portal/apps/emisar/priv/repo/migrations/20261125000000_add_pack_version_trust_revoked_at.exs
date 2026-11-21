defmodule Emisar.Repo.Migrations.AddPackVersionTrustRevokedAt do
  use Ecto.Migration

  def change do
    alter table(:catalog_pack_versions) do
      add :trust_revoked_at, :utc_datetime_usec
    end
  end
end
