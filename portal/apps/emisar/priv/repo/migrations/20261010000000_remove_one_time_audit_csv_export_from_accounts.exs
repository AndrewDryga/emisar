defmodule Emisar.Repo.Migrations.RemoveOneTimeAuditCsvExportFromAccounts do
  use Ecto.Migration

  def up do
    alter table(:accounts) do
      remove :one_time_audit_csv_exported_at
      remove :one_time_audit_csv_export_reservation_id
      remove :one_time_audit_csv_export_reserved_at
    end
  end

  def down do
    alter table(:accounts) do
      add :one_time_audit_csv_exported_at, :utc_datetime_usec
      add :one_time_audit_csv_export_reservation_id, :uuid
      add :one_time_audit_csv_export_reserved_at, :utc_datetime_usec
    end
  end
end
