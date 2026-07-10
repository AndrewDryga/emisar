defmodule Emisar.Repo.Migrations.DropActionRunsApprovalRequestId do
  use Ecto.Migration

  # `action_runs.approval_request_id` was never wired up: the create changeset
  # never cast it, no reader/writer touched it, and there was no FK. Approval
  # linkage lives on the `approval_grants` side (`grants.approval_request_id`).
  # Drop the dead column. `change/0` is reversible — `down` re-adds it empty.
  def change do
    alter table(:action_runs) do
      remove :approval_request_id, :binary_id
    end
  end
end
