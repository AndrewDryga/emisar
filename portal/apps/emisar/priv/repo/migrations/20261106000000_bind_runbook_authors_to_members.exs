defmodule Emisar.Repo.Migrations.BindRunbookAuthorsToMembers do
  use Ecto.Migration

  def up do
    alter table(:runbooks) do
      add :created_by_membership_id,
          references(:account_memberships,
            type: :binary_id,
            with: [account_id: :account_id],
            on_delete: {:nilify, [:created_by_membership_id]}
          )
    end

    alter table(:runbook_releases) do
      add :published_by_membership_id,
          references(:account_memberships,
            type: :binary_id,
            with: [account_id: :account_id],
            on_delete: {:nilify, [:published_by_membership_id]}
          )
    end

    create index(:runbooks, [:created_by_membership_id])
    create index(:runbook_releases, [:published_by_membership_id])

    # Keep the original User attribution even when there is no exact Member
    # history. A replacement seat is not the author of an older artifact.
    for {table, user_column, member_column} <- [
          {:runbooks, :created_by_id, :created_by_membership_id},
          {:runbook_releases, :published_by_id, :published_by_membership_id}
        ] do
      execute """
      WITH unambiguous AS (
        SELECT account_id, user_id, (array_agg(id))[1] AS id,
               min(inserted_at) AS inserted_at
        FROM account_memberships
        GROUP BY account_id, user_id
        HAVING count(*) = 1
      )
      UPDATE #{table} r SET #{member_column} = m.id
      FROM unambiguous m
      WHERE m.account_id = r.account_id AND m.user_id = r.#{user_column}
        AND m.inserted_at <= r.inserted_at
      """
    end
  end

  def down do
    alter table(:runbook_releases) do
      remove :published_by_membership_id
    end

    alter table(:runbooks) do
      remove :created_by_membership_id
    end
  end
end
