defmodule Emisar.Repo.Migrations.AddOneTimeAuditCsvExportToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :one_time_audit_csv_exported_at, :utc_datetime_usec
      add :one_time_audit_csv_export_reservation_id, :uuid
      add :one_time_audit_csv_export_reserved_at, :utc_datetime_usec
    end
  end
end
