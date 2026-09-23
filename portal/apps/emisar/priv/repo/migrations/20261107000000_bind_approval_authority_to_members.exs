defmodule Emisar.Repo.Migrations.BindApprovalAuthorityToMembers do
  use Ecto.Migration

  @anchors [
    {:approval_requests, :requested_by_id, :requested_by_membership_id, :requested_at},
    {:approval_requests, :decided_by_id, :decided_by_membership_id, :decided_at},
    {:approval_decisions, :decider_id, :decider_membership_id, :decided_at},
    {:approval_grants, :granted_by_id, :granted_by_membership_id, :granted_at},
    {:approval_grants, :revoked_by_id, :revoked_by_membership_id, :revoked_at}
  ]

  def up do
    for {table_name, _user_column, member_column, _event_column} <- @anchors do
      alter table(table_name) do
        add member_column,
            references(:account_memberships,
              type: :binary_id,
              with: [account_id: :account_id],
              on_delete: {:nilify, [member_column]}
            )
      end

      create index(table_name, [member_column])
    end

    # Initiator anchors predate this migration, but some were themselves
    # backfilled. A seat created after the request cannot prove its requester.
    execute """
    UPDATE approval_requests r SET requested_by_membership_id = m.id
    FROM action_runs run, account_memberships m
    WHERE run.id = r.run_id AND run.account_id = r.account_id
      AND m.id = run.initiating_membership_id AND m.account_id = r.account_id
      AND (r.requested_by_id IS NULL OR m.user_id = r.requested_by_id)
      AND m.inserted_at <= r.requested_at
    """

    execute """
    UPDATE approval_requests r SET requested_by_membership_id = m.id
    FROM runbook_executions execution, account_memberships m
    WHERE execution.id = r.runbook_execution_id AND execution.account_id = r.account_id
      AND m.id = execution.initiating_membership_id AND m.account_id = r.account_id
      AND (r.requested_by_id IS NULL OR m.user_id = r.requested_by_id)
      AND m.inserted_at <= r.requested_at
    """

    # Count tombstones too: the newest seat must not inherit earlier authorship.
    # Preserve every original User value, including unresolved terminal history.
    for {table_name, user_column, member_column, event_column} <- @anchors do
      execute """
      WITH unambiguous AS (
        SELECT account_id, user_id, (array_agg(id))[1] AS id,
               min(inserted_at) AS inserted_at
        FROM account_memberships
        GROUP BY account_id, user_id
        HAVING count(*) = 1
      )
      UPDATE #{table_name} r SET #{member_column} = m.id
      FROM unambiguous m
      WHERE r.#{member_column} IS NULL
        AND m.account_id = r.account_id AND m.user_id = r.#{user_column}
        AND m.inserted_at <= COALESCE(r.#{event_column}, r.inserted_at)
      """
    end

    refuse_unrepresentable_delegations(:up)

    create unique_index(:approval_decisions, [:request_id, :decider_membership_id])
    drop index(:approval_decisions, [:request_id, :decider_id])
  end

  def down do
    # Old code treats a NULL requester as somebody else and accepts grants
    # without an issuer. Never recover User attribution from today's link.
    refuse_rows(
      """
      SELECT r.id FROM approval_requests r
      WHERE r.status = 'pending' AND NOT r.allow_self_approval
        AND NOT EXISTS (
          SELECT 1 FROM account_memberships m
          WHERE m.id = r.requested_by_membership_id AND m.account_id = r.account_id
            AND m.user_id = r.requested_by_id
        )
      """,
      "protected requests cannot retain their requester on downgrade",
      "Deny or cancel these requests through the normal audited workflow before retrying."
    )

    refuse_unrepresentable_delegations(:down)

    create unique_index(:approval_decisions, [:request_id, :decider_id])
    drop index(:approval_decisions, [:request_id, :decider_membership_id])

    for {table_name, _user_column, member_column, _event_column} <- Enum.reverse(@anchors) do
      alter table(table_name) do
        remove member_column
      end
    end
  end

  defp refuse_unrepresentable_delegations(direction) do
    faithful_voter =
      if direction == :down, do: "AND m.user_id = d.decider_id", else: ""

    faithful_issuer =
      if direction == :down, do: "AND m.user_id = g.granted_by_id", else: ""

    refuse_rows(
      """
      SELECT d.id FROM approval_decisions d
      JOIN approval_requests r ON r.id = d.request_id AND r.account_id = d.account_id
      WHERE r.status = 'pending' AND d.decision = 'approve'
        AND NOT EXISTS (
          SELECT 1 FROM account_memberships m
          WHERE m.id = d.decider_membership_id AND m.account_id = d.account_id
            #{eligible_member_sql()} #{faithful_voter}
        )
      """,
      "pending votes lack safely attributable eligible Members (#{direction})",
      "Deny or cancel their requests through the normal audited workflow before retrying."
    )

    refuse_rows(
      """
      SELECT g.id FROM approval_grants g
      WHERE g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > CURRENT_TIMESTAMP)
        AND (g.max_uses IS NULL OR g.uses_count < g.max_uses)
        AND NOT EXISTS (
          SELECT 1 FROM account_memberships m
          WHERE m.id = g.granted_by_membership_id AND m.account_id = g.account_id
            #{eligible_member_sql()} #{faithful_issuer}
        )
      """,
      "reusable grants lack safely attributable eligible Members (#{direction})",
      "Revoke these grants through the normal audited workflow before retrying."
    )
  end

  # Snapshot of local approval permission, not session or provider freshness.
  # A disabled account or cap-zero grant may become usable again later.
  defp eligible_member_sql do
    """
    AND m.deleted_at IS NULL AND m.disabled_at IS NULL
    AND (m.invitation_token_digest IS NULL OR m.invitation_accepted_at IS NOT NULL)
    AND (m.role = 'owner' OR
      (m.role IN ('admin', 'operator') AND m.directory_authorization_pending_version IS NULL))
    """
  end

  defp refuse_rows(query, reason, recovery) do
    execute """
    DO $$
    DECLARE affected_count bigint; sample_ids text;
    BEGIN
      WITH affected AS (#{query})
      SELECT count(*), (SELECT string_agg(id::text, ', ')
                       FROM (SELECT id FROM affected ORDER BY id LIMIT 10) sample)
      INTO affected_count, sample_ids FROM affected;
      IF affected_count > 0 THEN
        RAISE EXCEPTION '#{reason}: % rows (first IDs: %). #{recovery}',
          affected_count, sample_ids;
      END IF;
    END $$
    """
  end
end
