defmodule Emisar.Repo.Migrations.SyncedDirectoryGroupsAreRows do
  @moduledoc """
  A synced group existed only as a side effect of its membership rows, so a group
  with no members did not exist at all. `POST /Groups` with `members: []`
  answered 201 and the immediate `GET` answered 404 — an IdP is entitled to
  believe the resource it just created is there. A group pushed before its users
  vanished the same way.

  It also made Entra's `displayName eq` probe answer "no such group" for a group
  it had already created, so it re-created it on every sync cycle.

  Groups become their own rows. Membership rows still carry members; existence
  and display belong to the group. Existing groups are backfilled from the
  distinct groups their membership rows name, taking the display those rows
  already hold.
  """
  use Ecto.Migration

  def change do
    create table(:sso_directory_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_id,
          references(:sso_identity_providers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :external_group_id, :string, null: false
      add :display, :string
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sso_directory_groups, [:provider_id])

    create unique_index(:sso_directory_groups, [:account_id, :provider_id, :external_group_id],
             where: "deleted_at IS NULL",
             name: :sso_directory_groups_live_index
           )

    execute(&backfill_from_member_rows/0, fn -> :ok end)
  end

  defp backfill_from_member_rows do
    repo().query!("""
    INSERT INTO sso_directory_groups
      (id, account_id, provider_id, external_group_id, display, inserted_at, updated_at)
    SELECT DISTINCT ON (g.account_id, g.provider_id, g.external_group_id)
           gen_random_uuid(), g.account_id, g.provider_id, g.external_group_id,
           g.external_group_display, now(), now()
    FROM sso_directory_group_members g
    WHERE g.deleted_at IS NULL
    ORDER BY g.account_id, g.provider_id, g.external_group_id,
             (g.external_group_display IS NOT NULL) DESC, g.inserted_at DESC
    """)
  end
end
