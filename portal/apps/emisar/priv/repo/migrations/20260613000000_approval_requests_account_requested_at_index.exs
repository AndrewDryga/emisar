defmodule Emisar.Repo.Migrations.ApprovalRequestsAccountRequestedAtIndex do
  use Ecto.Migration

  # The /app/approvals page (`Approvals.list_approval_requests_for_account/2`)
  # orders by `requested_at DESC`, scoped to `account_id`, with no status
  # filter. The existing indexes are `(account_id, status)` and `(run_id)` —
  # neither serves the unfiltered ordered list, so it falls back to a scan +
  # sort per page on a table that grows with every approval. Add the matching
  # `(account_id, requested_at)` index — the same fix the action_runs
  # `(account_id, inserted_at)` index made for the runs list. Standalone
  # corrective migration: the original `approvals_and_audit` migration has
  # already shipped to prod.
  def change do
    create index(:approval_requests, [:account_id, :requested_at])
  end
end
