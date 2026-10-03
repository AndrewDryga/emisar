defmodule Emisar.Repo.Migrations.GiveMembersTheirEmailAndFactor do
  use Ecto.Migration

  @pending "m.invitation_accepted_at IS NULL AND m.invitation_token_digest IS NOT NULL"

  @directory """
  (m.directory_managed OR EXISTS (
    SELECT 1 FROM sso_user_identities i
    WHERE i.membership_id = m.id AND i.deleted_at IS NULL AND i.scim_external_id IS NOT NULL
  ))
  """

  # A Member becomes the only person record: it gains one address, the proof of
  # that address, its own MFA factor and the staff flag. The personal login
  # (`users`) is only read here; later migrations re-key sessions and drop it.
  def up do
    alter table(:account_memberships) do
      add :email_verified_at, :utc_datetime_usec
      add :mfa_secret, :binary
      add :mfa_enabled_at, :utc_datetime_usec
      add :mfa_last_used_at, :utc_datetime_usec
      add :mfa_recovery_codes, {:array, :binary}, null: false, default: []
      add :staff, :boolean, null: false, default: false
    end

    rename table(:account_memberships), :contact_email, to: :email

    # One address per live Member. A pending invitation keeps the address it was
    # sent to and a directory-managed Member keeps its directory address; any
    # other Member linked to a live login takes the address that login signs in
    # with. Only that last case can be verified: the address then equals the
    # login's, so it carries the login's confirmation.
    execute """
    UPDATE account_memberships m
    SET email = CASE
          WHEN #{@pending} THEN m.invitation_sent_to
          WHEN #{@directory} THEN m.email
          ELSE COALESCE(u.email, m.email)
        END,
        display_name = COALESCE(m.display_name, u.full_name),
        email_verified_at = CASE
          WHEN NOT (#{@pending}) AND NOT #{@directory} AND u.email IS NOT NULL
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

    # The staff workspace is deployment configuration (`:staff_account_slug`),
    # read when this migration runs: the dev seed's workspace by default, the
    # production one from EMISAR_STAFF_ACCOUNT_SLUG.
    execute fn ->
      repo().query!(
        """
        UPDATE account_memberships m
        SET staff = true
        FROM users u, accounts a
        WHERE u.id = m.user_id AND u.deleted_at IS NULL AND u.is_admin
          AND a.id = m.account_id AND a.deleted_at IS NULL AND a.slug = $1
          AND m.deleted_at IS NULL
        """,
        [Application.fetch_env!(:emisar, :staff_account_slug)]
      )
    end

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
      remove :staff
    end
  end
end
