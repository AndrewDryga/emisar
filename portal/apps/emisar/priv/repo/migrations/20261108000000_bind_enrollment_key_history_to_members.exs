defmodule Emisar.Repo.Migrations.BindEnrollmentKeyHistoryToMembers do
  use Ecto.Migration

  def up do
    alter table(:runner_enrollment_keys) do
      add :created_by_membership_id,
          references(:account_memberships,
            type: :binary_id,
            with: [account_id: :account_id],
            on_delete: {:nilify, [:created_by_membership_id]}
          )

      add :revoked_by_membership_id,
          references(:account_memberships,
            type: :binary_id,
            with: [account_id: :account_id],
            on_delete: {:nilify, [:revoked_by_membership_id]}
          )
    end

    create index(:runner_enrollment_keys, [:created_by_membership_id])
    create index(:runner_enrollment_keys, [:revoked_by_membership_id])

    # Preserve old User facts. Unknown or ambiguous history cannot identify an
    # exact creator/revoker. These workspace credentials do not delegate the
    # creator's continuing authority, so a retired creator does not revoke a key.
    for {user_column, member_column, event_column} <- [
          {:created_by_id, :created_by_membership_id, :inserted_at},
          {:revoked_by_id, :revoked_by_membership_id, :revoked_at}
        ] do
      execute """
      WITH unambiguous AS (
        SELECT account_id, user_id, (array_agg(id))[1] AS id,
               min(inserted_at) AS inserted_at
        FROM account_memberships
        GROUP BY account_id, user_id
        HAVING count(*) = 1
      )
      UPDATE runner_enrollment_keys k SET #{member_column} = m.id
      FROM unambiguous m
      WHERE m.account_id = k.account_id AND m.user_id = k.#{user_column}
        AND m.inserted_at <= k.#{event_column}
      """
    end
  end

  def down do
    alter table(:runner_enrollment_keys) do
      remove :created_by_membership_id
      remove :revoked_by_membership_id
    end
  end
end
