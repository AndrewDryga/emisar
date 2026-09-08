defmodule Emisar.Repo.Migrations.AddOperatorCredentialRotation do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :auto_rotation_supported, :boolean, null: false, default: false
      add :rotation_requested_at, :utc_datetime_usec
    end

    alter table(:runners) do
      add :connection_token_id,
          references(:runner_tokens, type: :binary_id, on_delete: :nilify_all)

      add :credential_rotation_supported, :boolean, null: false, default: false
      add :credential_rotation_requested_at, :utc_datetime_usec
    end

    # Manual rotation used to record only the successor's replaces_id. Keep
    # pending replacements exclusive without removing historical branches.
    execute(
      """
      UPDATE api_keys AS source
      SET rotated_to_id = replacements.successor_id
      FROM (
        SELECT DISTINCT ON (parent.id) parent.id AS source_id, child.id AS successor_id
        FROM api_keys AS parent
        JOIN api_keys AS child ON child.replaces_id = parent.id
          AND child.account_id = parent.account_id
          AND child.created_by_membership_id = parent.created_by_membership_id
          AND child.credential_lineage_id = parent.credential_lineage_id
        WHERE parent.rotated_to_id IS NULL
          AND parent.deleted_at IS NULL AND parent.revoked_at IS NULL
          AND child.deleted_at IS NULL AND child.revoked_at IS NULL
          AND (child.expires_at IS NULL OR child.expires_at > now())
        ORDER BY parent.id, child.inserted_at DESC, child.id DESC
      ) AS replacements
      WHERE source.id = replacements.source_id AND source.rotated_to_id IS NULL
      """,
      "SELECT 1"
    )
  end
end
