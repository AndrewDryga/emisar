defmodule Emisar.Repo.Migrations.MarkOverriddenApprovalRequests do
  use Ecto.Migration

  def up do
    # NULL preserves unknown historical provenance and unmarked old-writer
    # finalizations during rollout. New code explicitly writes true or false.
    alter table(:approval_requests) do
      add(:overridden, :boolean)
    end

    execute("""
    UPDATE approval_requests AS r
    SET overridden = true
    FROM audit_events AS e
    WHERE e.event_type = 'approval.overridden'
      AND e.target_kind = 'approval_request'
      AND e.target_id = r.id
      AND e.account_id = r.account_id
    """)

    # A retained ordinary receipt or a decision predating the vote table is
    # positive evidence. Receipt absence alone is not: retention may have
    # deleted an override. A retained override above always wins.
    execute("""
    UPDATE approval_requests AS r
    SET overridden = false
    WHERE r.overridden IS NULL
      AND (
        r.status = 'denied'
        OR (
          r.status = 'approved'
          AND (
            EXISTS (
              SELECT 1 FROM audit_events AS e
              WHERE e.event_type = 'approval.approved'
                AND e.target_kind = 'approval_request'
                AND e.target_id = r.id
                AND e.account_id = r.account_id
            )
            OR (
              r.min_approvals = 1
              AND r.decided_at < (
                SELECT inserted_at FROM schema_migrations
                WHERE version = 20260616000000
              )
            )
          )
        )
      )
    """)
  end

  def down do
    alter table(:approval_requests) do
      remove(:overridden)
    end
  end
end
