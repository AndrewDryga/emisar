defmodule Emisar.Repo.Migrations.RenameAuditSubjectToTarget do
  use Ecto.Migration

  # The audit trail's acted-upon entity is a TARGET — "subject" collided with
  # %Auth.Subject{} (the authorization caller) everywhere else in the codebase,
  # and the UI already says Target. Metadata-only renames; existing indexes
  # follow their columns.
  def change do
    rename table(:audit_events), :subject_kind, to: :target_kind
    rename table(:audit_events), :subject_id, to: :target_id
    rename table(:audit_events), :subject_label, to: :target_label
  end
end
