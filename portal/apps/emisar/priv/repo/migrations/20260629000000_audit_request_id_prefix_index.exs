defmodule Emisar.Repo.Migrations.AuditRequestIdPrefixIndex do
  use Ecto.Migration

  # Corrective migration: the audit trace filter is account-scoped and
  # prefix-anchored. text_pattern_ops lets Postgres use the btree for
  # `LIKE 'req_%'` instead of scanning the account's whole audit history.
  def change do
    create index(:audit_events, [:account_id, "request_id text_pattern_ops"],
             name: :audit_events_account_request_id_prefix_index,
             where: "request_id IS NOT NULL"
           )
  end
end
