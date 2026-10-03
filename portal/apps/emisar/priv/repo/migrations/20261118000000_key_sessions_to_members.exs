defmodule Emisar.Repo.Migrations.KeySessionsToMembers do
  use Ecto.Migration

  # Sessions, emailed codes and attempt windows belonged to a personal login whose
  # one session reached every workspace it held. Each now belongs to exactly one
  # workspace Member. Nothing maps across: every browser signs in once more and
  # in-flight codes are lost. The SSO route a session proved (its identity and
  # the issuer and subject frozen at sign-in) moves onto the token, so the grant
  # tables go. Every session also records the digest of the browser that minted
  # it, so signing out of that browser ends them all. A sign-up code is the one
  # row with no Member: the workspace it creates does not exist until the code
  # comes back, and an address holds at most one.
  def up do
    execute "DELETE FROM auth_user_tokens"
    execute "DELETE FROM auth_security_attempt_windows"

    drop table(:auth_member_grant_routes)
    drop table(:auth_member_grants)

    drop constraint(:auth_user_tokens, :auth_user_tokens_member_only_session_check)
    drop index(:auth_user_tokens, [:user_id, :context])

    alter table(:auth_user_tokens) do
      remove :user_id
      remove :personal_proved_at
      remove :personal_expires_at
      add :account_id, :binary_id
      add :membership_id, :binary_id
      add :sso_issuer, :text
      add :sso_provider_identifier, :text
      add :browser_digest, :binary
    end

    execute """
    ALTER TABLE auth_user_tokens ADD CONSTRAINT auth_user_tokens_membership_fkey
      FOREIGN KEY (account_id, membership_id)
      REFERENCES account_memberships (account_id, id) ON DELETE CASCADE
    """

    create index(:auth_user_tokens, [:account_id, :membership_id, :context])
    create index(:auth_user_tokens, [:browser_digest])

    create unique_index(:auth_user_tokens, ["lower(sent_to)"],
             where: "context = 'sign_up'",
             name: :auth_user_tokens_sign_up_address_index
           )

    create constraint(:auth_user_tokens, :auth_user_tokens_owner_check,
             check: """
             (context = 'sign_up' AND account_id IS NULL AND membership_id IS NULL)
             OR (context <> 'sign_up' AND account_id IS NOT NULL AND membership_id IS NOT NULL)
             """
           )

    create constraint(:auth_user_tokens, :auth_user_tokens_session_proof_check,
             check: """
             (context <> 'session' AND browser_digest IS NULL)
             OR (context = 'session' AND browser_digest IS NOT NULL AND (
               (auth_method = 'magic_link' AND user_identity_id IS NULL
                AND sso_issuer IS NULL AND sso_provider_identifier IS NULL)
               OR (auth_method = 'sso' AND sso_issuer IS NOT NULL
                   AND sso_provider_identifier IS NOT NULL)
             ))
             """
           )

    drop index(:auth_security_attempt_windows, [:user_id, :scope])

    alter table(:auth_security_attempt_windows) do
      remove :user_id

      add :membership_id,
          references(:account_memberships, type: :binary_id, on_delete: :delete_all),
          null: false
    end

    create unique_index(:auth_security_attempt_windows, [:membership_id, :scope])

    drop constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check)

    create constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check,
             check:
               "scope IN ('mfa_challenge', 'inbox_step_up', 'mfa_enrollment_issue', 'oidc_identity_step_up_issue')"
           )
  end

  def down do
    execute "DELETE FROM auth_user_tokens"
    execute "DELETE FROM auth_security_attempt_windows"

    drop constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check)

    create constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check,
             check:
               "scope IN ('mfa_challenge', 'inbox_step_up', 'email_change_issue', 'mfa_enrollment_issue', 'oidc_identity_step_up_issue')"
           )

    drop index(:auth_security_attempt_windows, [:membership_id, :scope])

    alter table(:auth_security_attempt_windows) do
      remove :membership_id
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
    end

    create unique_index(:auth_security_attempt_windows, [:user_id, :scope])

    drop constraint(:auth_user_tokens, :auth_user_tokens_session_proof_check)
    drop constraint(:auth_user_tokens, :auth_user_tokens_owner_check)
    drop index(:auth_user_tokens, [:account_id, :membership_id, :context])
    drop index(:auth_user_tokens, [:browser_digest])

    drop index(:auth_user_tokens, ["lower(sent_to)"],
           name: :auth_user_tokens_sign_up_address_index
         )

    execute "ALTER TABLE auth_user_tokens DROP CONSTRAINT auth_user_tokens_membership_fkey"

    alter table(:auth_user_tokens) do
      remove :account_id
      remove :membership_id
      remove :sso_issuer
      remove :sso_provider_identifier
      remove :browser_digest
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :personal_proved_at, :utc_datetime_usec
      add :personal_expires_at, :utc_datetime_usec
    end

    create index(:auth_user_tokens, [:user_id, :context])

    create constraint(:auth_user_tokens, :auth_user_tokens_member_only_session_check,
             check: """
             user_id IS NOT NULL OR (
               context = 'session' AND auth_method = 'sso'
               AND personal_proved_at IS NULL AND mfa_enrollment_verified_at IS NULL
             )
             """
           )

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
    """

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
    """

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
