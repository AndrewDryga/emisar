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

    create unique_index(:approval_decisions, [:request_id, :decider_membership_id])
    drop index(:approval_decisions, [:request_id, :decider_id])
  end

  def down do
    create unique_index(:approval_decisions, [:request_id, :decider_id])
    drop index(:approval_decisions, [:request_id, :decider_membership_id])

    for {table_name, _user_column, member_column, _event_column} <- Enum.reverse(@anchors) do
      alter table(table_name) do
        remove member_column
      end
    end
  end
end
