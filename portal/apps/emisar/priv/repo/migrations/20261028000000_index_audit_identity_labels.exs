defmodule Emisar.Repo.Migrations.IndexAuditIdentityLabels do
  use Ecto.Migration
  alias Emisar.Release.IndexRecovery

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Keep the ordinary identity indexes: current-label evidence includes events
  # without a snapshot. These partial indexes serve latest historical labels
  # without reading and sorting every event belonging to an unresolved identity.
  def up do
    IndexRecovery.ensure_index(
      repo(),
      prefix(),
      "audit_events",
      ["account_id", "actor_kind", "actor_id", {"occurred_at", :desc}, {"id", :desc}],
      name: "audit_events_actor_latest_label_idx",
      predicate: :actor_label
    )

    IndexRecovery.ensure_index(
      repo(),
      prefix(),
      "audit_events",
      ["account_id", "target_kind", "target_id", {"occurred_at", :desc}, {"id", :desc}],
      name: "audit_events_target_latest_label_idx",
      predicate: :target_label
    )
  end

  def down do
    IndexRecovery.drop_index(
      repo(),
      prefix(),
      "audit_events",
      ["account_id", "target_kind", "target_id", {"occurred_at", :desc}, {"id", :desc}],
      name: "audit_events_target_latest_label_idx",
      predicate: :target_label
    )

    IndexRecovery.drop_index(
      repo(),
      prefix(),
      "audit_events",
      ["account_id", "actor_kind", "actor_id", {"occurred_at", :desc}, {"id", :desc}],
      name: "audit_events_actor_latest_label_idx",
      predicate: :actor_label
    )
  end
end
