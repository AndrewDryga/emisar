defmodule Emisar.Repo.Migrations.GiveMembersTheirEmailAndFactor do
  use Ecto.Migration

  @pending "m.invitation_accepted_at IS NULL AND m.invitation_token_digest IS NOT NULL"

  # Members the directory or an SSO sign-in created sign in through SSO only, so
  # they keep their directory address and stay unverified even when a personal
  # login was later linked to them: a seat the directory manages or holds through
  # SCIM, and a seat created together with an OIDC JIT, SCIM or admin-approved
  # identity that never accepted an invitation (the definition 20261113 used to
  # unlink such seats; a deleted identity still records how the seat began).
  @sso_created """
  (m.directory_managed
    OR EXISTS (
      SELECT 1 FROM sso_user_identities i
      WHERE i.membership_id = m.id AND i.deleted_at IS NULL AND i.scim_external_id IS NOT NULL
    )
    OR (m.invitation_accepted_at IS NULL AND EXISTS (
      SELECT 1 FROM sso_user_identities i
      WHERE i.membership_id = m.id
        AND (i.provisioned_via IN ('oidc_jit', 'scim')
          OR (i.provisioned_via = 'manual' AND i.created_by = 'admin'))
        AND abs(extract(epoch FROM (i.inserted_at - m.inserted_at))) < 10
    )))
  """

  # A Member becomes the only person record: it gains one address, the proof of
  # that address and its own MFA factor. The personal login (`users`) is only
  # read here; later migrations re-key sessions and drop it.
  def up do
    alter table(:account_memberships) do
      add :email_verified_at, :utc_datetime_usec
      add :mfa_secret, :binary
      add :mfa_enabled_at, :utc_datetime_usec
      add :mfa_last_used_at, :utc_datetime_usec
      add :mfa_recovery_codes, {:array, :binary}, null: false, default: []
    end

    rename table(:account_memberships), :contact_email, to: :email

    # One address per live Member. A pending invitation keeps the address it was
    # sent to and an SSO-created Member keeps its directory address; any other
    # Member linked to a live login takes the address that login signs in with.
    # Only that last case can be verified: the address then equals the login's,
    # so it carries the login's confirmation.
    execute """
    UPDATE account_memberships m
    SET email = CASE
          WHEN #{@pending} THEN m.invitation_sent_to
          WHEN #{@sso_created} THEN m.email
          ELSE COALESCE(u.email, m.email)
        END,
        display_name = COALESCE(m.display_name, u.full_name),
        email_verified_at = CASE
          WHEN NOT (#{@pending}) AND NOT #{@sso_created} AND u.email IS NOT NULL
          THEN u.confirmed_at
        END
    FROM account_memberships self
    LEFT JOIN users u ON u.id = self.user_id AND u.deleted_at IS NULL
    WHERE self.id = m.id AND m.deleted_at IS NULL
    """

    alter table(:account_memberships) do
      remove :invitation_sent_to
    end

    # A person with exactly one live Member keeps their authenticator on it. With
    # two or more nothing is copied, so one secret never spans workspaces; those
    # people enroll again in each workspace.
    execute """
    UPDATE account_memberships m
    SET mfa_secret = u.mfa_secret,
        mfa_enabled_at = u.mfa_enabled_at,
        mfa_last_used_at = u.mfa_last_used_at,
        mfa_recovery_codes = COALESCE(u.mfa_recovery_codes, ARRAY[]::bytea[])
    FROM users u, accounts a
    WHERE u.id = m.user_id AND u.deleted_at IS NULL AND u.mfa_enabled_at IS NOT NULL
      AND a.id = m.account_id AND a.deleted_at IS NULL
      AND m.deleted_at IS NULL
      AND (
        SELECT count(*)
        FROM account_memberships other
        JOIN accounts other_account
          ON other_account.id = other.account_id AND other_account.deleted_at IS NULL
        WHERE other.user_id = u.id AND other.deleted_at IS NULL
      ) = 1
    """

    create unique_index(:account_memberships, [:account_id, :email],
             where: "deleted_at IS NULL AND email IS NOT NULL"
           )
  end

  # Restores the structure. Addresses and names the backfill wrote stay as the
  # contact, the copied factors are dropped with their columns, and `users` was
  # never written, so the earlier build finds every login as it left it.
  def down do
    drop index(:account_memberships, [:account_id, :email])

    alter table(:account_memberships) do
      add :invitation_sent_to, :citext
    end

    execute """
    UPDATE account_memberships m
    SET invitation_sent_to = m.email
    WHERE #{@pending}
    """

    rename table(:account_memberships), :email, to: :contact_email

    alter table(:account_memberships) do
      remove :email_verified_at
      remove :mfa_secret
      remove :mfa_enabled_at
      remove :mfa_last_used_at
      remove :mfa_recovery_codes
    end
  end
end
