defmodule Emisar.Repo.Migrations.TrackLocalAuditFailure do
  use Ecto.Migration

  def change do
    alter table(:action_runs) do
      add :local_audit_failed, :boolean, null: false, default: false
    end
  end
end
