defmodule Emisar.Repo.Migrations.DropUserAttributionColumns do
  use Ecto.Migration

  # Every record of who did something now names the workspace Member. The
  # personal-login columns beside those anchors only duplicated them and have
  # no reader left.
  @columns [
    action_runs: [:requested_by_id],
    runbook_executions: [:requested_by_id],
    runbooks: [:created_by_id],
    runbook_releases: [:published_by_id],
    approval_requests: [:requested_by_id, :decided_by_id],
    approval_decisions: [:decider_id],
    approval_grants: [:granted_by_id, :revoked_by_id],
    runner_enrollment_keys: [:created_by_id, :revoked_by_id],
    policies: [:updated_by_id],
    api_keys: [:created_by_id, :revoked_by_id],
    api_key_device_grants: [:approved_by_id],
    catalog_pack_versions: [:retirement_overridden_by_id],
    sso_identity_providers: [:sign_in_verified_by_user_id],
    account_memberships: [:invited_by_id, :disabled_by_id]
  ]

  # The single-column indexes that go with their columns; down/0 restores them.
  @indexes [
    action_runs: [:requested_by_id],
    runbook_executions: [:requested_by_id],
    approval_requests: [:requested_by_id],
    approval_requests: [:decided_by_id],
    approval_decisions: [:decider_id],
    approval_grants: [:granted_by_id],
    approval_grants: [:revoked_by_id],
    account_memberships: [:disabled_by_id]
  ]

  def up do
    # A runbook whose author has no Member anchor takes the author's seat that
    # was live when the runbook was created, a removed seat included. A seat
    # that began later is a replacement and never counts; without exactly one
    # qualifying seat the author stays unknown.
    execute """
    UPDATE runbooks r
    SET created_by_membership_id = m.id
    FROM account_memberships m
    WHERE r.created_by_membership_id IS NULL
      AND r.created_by_id IS NOT NULL
      AND m.account_id = r.account_id
      AND m.user_id = r.created_by_id
      AND m.inserted_at <= r.inserted_at
      AND (m.deleted_at IS NULL OR m.deleted_at > r.inserted_at)
      AND NOT EXISTS (
        SELECT 1 FROM account_memberships other
        WHERE other.account_id = r.account_id
          AND other.user_id = r.created_by_id
          AND other.id <> m.id
          AND other.inserted_at <= r.inserted_at
          AND (other.deleted_at IS NULL OR other.deleted_at > r.inserted_at)
      )
    """

    for {table, columns} <- @columns do
      alter table(table) do
        for column <- columns, do: remove(column)
      end
    end
  end

  # Structure only: a seat's current personal login is no proof of who acted,
  # so the values are not refilled. The runbook anchor written above stays.
  def down do
    for {table, columns} <- @columns do
      alter table(table) do
        for column <- columns do
          add column, references(:users, type: :binary_id, on_delete: :nilify_all)
        end
      end
    end

    for {table, columns} <- @indexes, do: create(index(table, columns))
  end
end
