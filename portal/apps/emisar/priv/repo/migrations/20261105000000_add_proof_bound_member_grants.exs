defmodule Emisar.Repo.Migrations.AddProofBoundMemberGrants do
  use Ecto.Migration

  def change do
    alter table(:auth_user_tokens) do
      add :personal_proved_at, :utc_datetime_usec
      add :personal_expires_at, :utc_datetime_usec
      add :local_mfa_expires_at, :utc_datetime_usec
    end

    # Existing bearers carry no durable destination proof. Do not manufacture
    # grants from today's memberships or turn old IdP assertions into personal
    # authentication; these sessions must authenticate again.
    create table(:auth_member_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_token_id, references(:auth_user_tokens, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, :binary_id, null: false
      add :membership_id, :binary_id, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:auth_member_grants, [:user_token_id, :account_id])
    create unique_index(:auth_member_grants, [:id, :account_id, :membership_id])
    create index(:auth_member_grants, [:account_id, :membership_id])

    execute """
            ALTER TABLE auth_member_grants ADD CONSTRAINT auth_member_grants_membership_fkey
            FOREIGN KEY (account_id, membership_id)
            REFERENCES account_memberships (account_id, id) ON DELETE CASCADE
            """,
            "ALTER TABLE auth_member_grants DROP CONSTRAINT auth_member_grants_membership_fkey"

    create table(:auth_member_grant_routes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :member_grant_id, :binary_id, null: false
      add :account_id, :binary_id, null: false
      add :membership_id, :binary_id, null: false
      add :auth_method, :string, null: false

      add :user_identity_id,
          references(:sso_user_identities, type: :binary_id, on_delete: :delete_all)

      add :issuer, :text
      add :provider_identifier, :text
      add :direct, :boolean, null: false
      add :proved_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :idp_mfa_verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:auth_member_grant_routes, [:member_grant_id])
    create index(:auth_member_grant_routes, [:user_identity_id])

    execute """
            ALTER TABLE auth_member_grant_routes ADD CONSTRAINT auth_member_grant_routes_grant_fkey
            FOREIGN KEY (member_grant_id, account_id, membership_id)
            REFERENCES auth_member_grants (id, account_id, membership_id) ON DELETE CASCADE
            """,
            "ALTER TABLE auth_member_grant_routes DROP CONSTRAINT auth_member_grant_routes_grant_fkey"

    create constraint(:auth_member_grant_routes, :auth_member_grant_routes_proof_check,
             check: """
             expires_at > proved_at AND (
               (auth_method = 'magic_link' AND direct AND user_identity_id IS NULL
                AND issuer IS NULL AND provider_identifier IS NULL AND idp_mfa_verified_at IS NULL)
               OR
               (auth_method = 'sso' AND user_identity_id IS NOT NULL
                AND issuer IS NOT NULL AND provider_identifier IS NOT NULL)
             )
             """
           )
  end
end
