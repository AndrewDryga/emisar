defmodule Emisar.Repo.Migrations.RecoverSkippedConcurrentIndexes do
  use Ecto.Migration
  alias Emisar.Release.IndexRecovery

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    IndexRecovery.ensure_index(repo(), prefix(), "action_runs", ~w(inserted_at),
      name: "action_runs_inserted_at_idx"
    )

    IndexRecovery.ensure_index(
      repo(),
      prefix(),
      "audit_events",
      ["account_id", {"occurred_at", :desc}, "id"],
      name: "audit_events_account_console_keyset_idx"
    )
  end

  def down do
    raise "index validity repair cannot be reversed"
  end
end
