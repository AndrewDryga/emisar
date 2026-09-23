defmodule Emisar.Repo.Migrations.BindAdministrativeReceiptsToMembers do
  use Ecto.Migration

  @anchors [
    {:policies, :updated_by_id, :updated_by_membership_id, :updated_at},
    {:api_keys, :revoked_by_id, :revoked_by_membership_id, :revoked_at},
    {:catalog_pack_versions, :retirement_overridden_by_id,
     :retirement_overridden_by_membership_id, :retirement_overridden_at},
    {:sso_identity_providers, :sign_in_verified_by_user_id, :sign_in_verified_by_membership_id,
     :sign_in_verified_at},
    {:account_memberships, :invited_by_id, :invited_by_membership_id, :inserted_at},
    {:account_memberships, :disabled_by_id, :disabled_by_membership_id, :disabled_at}
  ]

  def up do
    for {table_name, user_column, member_column, event_column} <- @anchors do
      # The natural Catalog constraint/index names exceed PostgreSQL's limit.
      reference_options =
        if table_name == :catalog_pack_versions,
          do: [name: :catalog_pack_versions_override_member_fkey],
          else: []

      alter table(table_name) do
        add member_column,
            references(
              :account_memberships,
              [
                type: :binary_id,
                with: [account_id: :account_id],
                on_delete: {:nilify, [member_column]}
              ] ++ reference_options
            )
      end

      if table_name == :catalog_pack_versions do
        create index(table_name, [member_column],
                 name: :catalog_pack_versions_override_member_index
               )
      else
        create index(table_name, [member_column])
      end

      # These are historical receipts, not continuing delegation. Preserve
      # their operational state even when the exact actor cannot be recovered.
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
      WHERE m.account_id = r.account_id AND m.user_id = r.#{user_column}
        AND m.inserted_at <= r.#{event_column}
      """
    end
  end

  def down do
    for {table_name, _user_column, member_column, _event_column} <- Enum.reverse(@anchors) do
      alter table(table_name) do
        remove member_column
      end
    end
  end
end
