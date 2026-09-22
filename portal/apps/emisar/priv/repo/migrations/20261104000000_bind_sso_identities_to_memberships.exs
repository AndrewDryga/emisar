defmodule Emisar.Repo.Migrations.BindSSOIdentitiesToMemberships do
  use Ecto.Migration

  def up do
    create unique_index(:account_memberships, [:account_id, :id])
    create unique_index(:sso_user_identities, [:account_id, :id])

    alter table(:sso_user_identities) do
      add :membership_id, :binary_id
    end

    alter table(:sso_link_requests) do
      add :matched_membership_id, :binary_id
      add :recovery_identity_id, :binary_id
    end

    # Multiple histories cannot tell us which seat an old credential proved.
    # Leave those bindings unresolved; an explicit link or directory re-POST
    # can recover them. Never guess the latest seat or create one in a migration.
    execute """
    WITH unambiguous AS (
      SELECT account_id, user_id, (array_agg(id))[1] AS id
      FROM account_memberships
      GROUP BY account_id, user_id
      HAVING count(*) = 1
    )
    UPDATE sso_user_identities i SET membership_id = m.id
    FROM unambiguous m
    WHERE m.account_id = i.account_id AND m.user_id = i.user_id
    """

    execute """
    WITH unambiguous AS (
      SELECT account_id, user_id, (array_agg(id))[1] AS id,
             min(inserted_at) AS inserted_at
      FROM account_memberships
      GROUP BY account_id, user_id
      HAVING count(*) = 1
    )
    UPDATE sso_link_requests r SET matched_membership_id = m.id
    FROM unambiguous m
    WHERE m.account_id = r.account_id AND m.user_id = r.matched_user_id
      AND m.inserted_at <= r.inserted_at
    """

    execute """
    ALTER TABLE sso_user_identities
    ADD CONSTRAINT sso_user_identities_membership_account_fkey
    FOREIGN KEY (account_id, membership_id)
    REFERENCES account_memberships (account_id, id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE sso_link_requests
    ADD CONSTRAINT sso_link_requests_membership_account_fkey
    FOREIGN KEY (account_id, matched_membership_id)
    REFERENCES account_memberships (account_id, id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE sso_link_requests
    ADD CONSTRAINT sso_link_requests_recovery_identity_account_fkey
    FOREIGN KEY (account_id, recovery_identity_id)
    REFERENCES sso_user_identities (account_id, id) ON DELETE CASCADE
    """

    create index(:sso_user_identities, [:membership_id])
    create index(:sso_link_requests, [:matched_membership_id])
    create index(:sso_link_requests, [:recovery_identity_id])
  end

  def down do
    alter table(:sso_link_requests) do
      remove :matched_membership_id
      remove :recovery_identity_id
    end

    alter table(:sso_user_identities) do
      remove :membership_id
    end

    drop index(:account_memberships, [:account_id, :id])
    drop index(:sso_user_identities, [:account_id, :id])
  end
end
