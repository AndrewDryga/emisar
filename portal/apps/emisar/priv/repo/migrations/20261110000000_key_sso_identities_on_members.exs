defmodule Emisar.Repo.Migrations.KeySSOIdentitiesOnMembers do
  use Ecto.Migration

  # An SSO identity and a pending link request belong to an exact workspace
  # Member, which already carries its person. The User columns only duplicated
  # that and must not survive Members that have no personal login.
  def up do
    drop index(:sso_user_identities, [:account_id, :provider_id, :user_id],
           name: :sso_user_identities_live_user_index
         )

    alter table(:sso_user_identities) do
      remove :user_id
    end

    create unique_index(:sso_user_identities, [:account_id, :provider_id, :membership_id],
             where: "deleted_at IS NULL",
             name: :sso_user_identities_live_membership_index
           )

    alter table(:sso_link_requests) do
      remove :matched_user_id
    end
  end

  def down do
    alter table(:sso_link_requests) do
      add :matched_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    execute """
    UPDATE sso_link_requests r SET matched_user_id = m.user_id
    FROM account_memberships m
    WHERE m.id = r.matched_membership_id
    """

    drop index(:sso_user_identities, [:account_id, :provider_id, :membership_id],
           name: :sso_user_identities_live_membership_index
         )

    alter table(:sso_user_identities) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    execute """
    UPDATE sso_user_identities i SET user_id = m.user_id
    FROM account_memberships m
    WHERE m.id = i.membership_id
    """

    execute "ALTER TABLE sso_user_identities ALTER COLUMN user_id SET NOT NULL"
    create index(:sso_user_identities, [:user_id])

    create unique_index(:sso_user_identities, [:account_id, :provider_id, :user_id],
             where: "deleted_at IS NULL",
             name: :sso_user_identities_live_user_index
           )
  end
end
