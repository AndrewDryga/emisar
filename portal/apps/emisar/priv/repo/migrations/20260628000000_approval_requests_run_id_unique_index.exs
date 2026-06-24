defmodule Emisar.Repo.Migrations.ApprovalRequestsRunIdUniqueIndex do
  use Ecto.Migration

  # Corrective migration: production had already run the original
  # approvals_and_audit migration when the run_id index was tightened from a
  # plain index to the unique arbiter required by create_request_in_multi/5's
  # `ON CONFLICT (run_id)`. Rebuild it in place for migrated databases.
  def up do
    drop_if_exists index(:approval_requests, [:run_id])
    create unique_index(:approval_requests, [:run_id])
  end

  def down do
    :ok
  end
end
