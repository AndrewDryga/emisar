defmodule Emisar.Repo.Migrations.BindAuthorizationMappingsToDirectoryGroups do
  @moduledoc """
  Group authorization follows the server-owned SCIM resource id.

  An IdP may omit `externalId` (Okta does this for Group POST), and displayName
  is mutable and non-unique. Both mapping tables therefore point at the exact
  directory-group row. Existing mappings are backfilled only by an exact live
  account/provider/externalId match; unresolved rows are retired rather than
  guessed by display text.
  """
  use Ecto.Migration

  def up do
    create unique_index(:sso_directory_groups, [:account_id, :provider_id, :id],
             name: :sso_directory_groups_account_provider_id_index
           )

    add_directory_group_id(:sso_directory_group_role_mappings)
    add_directory_group_id(:sso_directory_group_runner_access_mappings)

    backfill_directory_group_ids(:sso_directory_group_role_mappings)
    backfill_directory_group_ids(:sso_directory_group_runner_access_mappings)

    retire_unresolved_mappings(:sso_directory_group_role_mappings)
    retire_unresolved_mappings(:sso_directory_group_runner_access_mappings)

    replace_mapping_identity(
      :sso_directory_group_role_mappings,
      :sso_directory_group_role_mappings_provider_group_index,
      :sso_group_role_mappings_provider_group_id_index,
      :sso_group_role_mapping_directory_group_fkey,
      :sso_directory_group_role_mappings_live_group_check
    )

    replace_mapping_identity(
      :sso_directory_group_runner_access_mappings,
      :sso_directory_group_runner_access_mappings_provider_group_index,
      :sso_group_access_mappings_provider_group_id_index,
      :sso_group_runner_access_mapping_directory_group_fkey,
      :sso_directory_group_runner_access_mappings_live_group_check
    )
  end

  def down do
    restore_external_group_ids(:sso_directory_group_role_mappings)
    restore_external_group_ids(:sso_directory_group_runner_access_mappings)

    restore_mapping_identity(
      :sso_directory_group_role_mappings,
      :sso_directory_group_role_mappings_provider_group_index,
      :sso_group_role_mappings_provider_group_id_index,
      :sso_group_role_mapping_directory_group_fkey,
      :sso_directory_group_role_mappings_live_group_check
    )

    restore_mapping_identity(
      :sso_directory_group_runner_access_mappings,
      :sso_directory_group_runner_access_mappings_provider_group_index,
      :sso_group_access_mappings_provider_group_id_index,
      :sso_group_runner_access_mapping_directory_group_fkey,
      :sso_directory_group_runner_access_mappings_live_group_check
    )

    drop index(:sso_directory_groups, [:account_id, :provider_id, :id],
           name: :sso_directory_groups_account_provider_id_index
         )
  end

  defp add_directory_group_id(table_name) do
    alter table(table_name) do
      add :directory_group_id, :binary_id
      modify :external_group_id, :string, null: true, from: {:string, null: false}
    end
  end

  defp backfill_directory_group_ids(table_name) do
    execute """
    UPDATE #{table_name} AS mappings
    SET directory_group_id = groups.id,
        external_group_display = COALESCE(groups.display, mappings.external_group_display),
        updated_at = now()
    FROM sso_directory_groups AS groups
    WHERE mappings.directory_group_id IS NULL
      AND mappings.deleted_at IS NULL
      AND groups.deleted_at IS NULL
      AND mappings.account_id = groups.account_id
      AND mappings.provider_id = groups.provider_id
      AND mappings.external_group_id = groups.external_group_id
    """
  end

  defp retire_unresolved_mappings(table_name) do
    execute """
    UPDATE #{table_name}
    SET deleted_at = now(), updated_at = now()
    WHERE deleted_at IS NULL AND directory_group_id IS NULL
    """
  end

  defp replace_mapping_identity(
         table_name,
         old_index,
         new_index,
         foreign_key,
         live_check
       ) do
    drop index(table_name, [:provider_id, :external_group_id], name: old_index)

    create unique_index(table_name, [:provider_id, :directory_group_id],
             where: "deleted_at IS NULL",
             name: new_index
           )

    execute """
    ALTER TABLE #{table_name}
    ADD CONSTRAINT #{foreign_key}
    FOREIGN KEY (account_id, provider_id, directory_group_id)
    REFERENCES sso_directory_groups (account_id, provider_id, id)
    ON DELETE CASCADE
    """

    create constraint(table_name, live_check,
             check: "deleted_at IS NOT NULL OR directory_group_id IS NOT NULL"
           )
  end

  defp restore_external_group_ids(table_name) do
    execute """
    UPDATE #{table_name} AS mappings
    SET external_group_id = groups.external_group_id,
        external_group_display = COALESCE(groups.display, mappings.external_group_display),
        updated_at = now()
    FROM sso_directory_groups AS groups
    WHERE mappings.directory_group_id = groups.id
      AND mappings.account_id = groups.account_id
      AND mappings.provider_id = groups.provider_id
    """

    execute "DELETE FROM #{table_name} WHERE external_group_id IS NULL"
  end

  defp restore_mapping_identity(
         table_name,
         old_index,
         new_index,
         foreign_key,
         live_check
       ) do
    drop constraint(table_name, live_check)
    execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{foreign_key}"
    drop index(table_name, [:provider_id, :directory_group_id], name: new_index)

    create unique_index(table_name, [:provider_id, :external_group_id],
             where: "deleted_at IS NULL",
             name: old_index
           )

    alter table(table_name) do
      remove :directory_group_id
      modify :external_group_id, :string, null: false, from: {:string, null: true}
    end
  end
end
