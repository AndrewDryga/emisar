defmodule Emisar.Repo.Migrations.GiveScimGroupsServerIds do
  @moduledoc """
  SCIM resource ids belong to the service provider. Directory groups already
  have UUIDs, but memberships still addressed them through the IdP's optional
  `externalId`, which made an externalId-less activation probe impossible to
  represent safely.

  Memberships now point at the directory-group row. The external id stays as a
  denormalized mapping key when the IdP supplied one.
  """
  use Ecto.Migration

  def up do
    alter table(:sso_directory_groups) do
      modify :external_group_id, :string, null: true, from: {:string, null: false}
    end

    alter table(:sso_directory_group_members) do
      add :directory_group_id,
          references(:sso_directory_groups,
            type: :binary_id,
            on_delete: :delete_all
          )

      modify :external_group_id, :string, null: true, from: {:string, null: false}
    end

    execute("""
    UPDATE sso_directory_group_members AS members
    SET directory_group_id = groups.id
    FROM sso_directory_groups AS groups
    WHERE members.directory_group_id IS NULL
      AND members.deleted_at IS NULL
      AND groups.deleted_at IS NULL
      AND members.account_id = groups.account_id
      AND members.provider_id = groups.provider_id
      AND members.external_group_id = groups.external_group_id
    """)

    create index(:sso_directory_group_members, [:directory_group_id])

    create unique_index(
             :sso_directory_group_members,
             [:directory_group_id, :user_identity_id],
             where: "deleted_at IS NULL",
             name: :sso_directory_group_members_resource_membership_index
           )

    create constraint(:sso_directory_group_members, :live_membership_has_directory_group,
             check: "deleted_at IS NOT NULL OR directory_group_id IS NOT NULL"
           )
  end

  def down do
    drop constraint(:sso_directory_group_members, :live_membership_has_directory_group)
    drop index(:sso_directory_group_members, [:directory_group_id])

    drop index(:sso_directory_group_members, [:directory_group_id, :user_identity_id],
           name: :sso_directory_group_members_resource_membership_index
         )

    alter table(:sso_directory_group_members) do
      remove :directory_group_id
      modify :external_group_id, :string, null: false, from: {:string, null: true}
    end

    alter table(:sso_directory_groups) do
      modify :external_group_id, :string, null: false, from: {:string, null: true}
    end
  end
end
