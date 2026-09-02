defmodule Emisar.Repo.Migrations.GuardInvitationCredentialTransitions do
  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION account_memberships_revoke_invitation_credentials()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.invitation_accepted_at IS NULL
         AND OLD.invitation_token_digest IS NOT NULL
         AND (NEW.invitation_accepted_at IS NOT NULL
              OR NEW.invitation_token_digest IS NULL) THEN
        UPDATE api_keys
        SET revoked_at = NOW(), updated_at = NOW()
        WHERE created_by_membership_id = NEW.id
          AND deleted_at IS NULL
          AND revoked_at IS NULL;

        UPDATE api_key_device_grants
        SET status = 'denied', updated_at = NOW()
        WHERE approved_by_membership_id = NEW.id
          AND status = 'approved';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER account_memberships_revoke_invitation_credentials
    AFTER UPDATE OF invitation_accepted_at, invitation_token_digest ON account_memberships
    FOR EACH ROW EXECUTE FUNCTION account_memberships_revoke_invitation_credentials()
    """

    execute """
    CREATE FUNCTION api_keys_reject_pending_invitation()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.deleted_at IS NULL
         AND NEW.revoked_at IS NULL
         AND EXISTS (
           SELECT 1
           FROM account_memberships
           WHERE id = NEW.created_by_membership_id
             AND invitation_accepted_at IS NULL
             AND invitation_token_digest IS NOT NULL
         ) THEN
        RAISE EXCEPTION 'an unresolved invitation cannot mint an API key'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER api_keys_reject_pending_invitation
    BEFORE INSERT ON api_keys
    FOR EACH ROW EXECUTE FUNCTION api_keys_reject_pending_invitation()
    """

    execute """
    CREATE FUNCTION api_key_device_grants_reject_pending_invitation()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.status = 'approved'
         AND NEW.approved_by_membership_id IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM account_memberships
           WHERE id = NEW.approved_by_membership_id
             AND invitation_accepted_at IS NULL
             AND invitation_token_digest IS NOT NULL
         ) THEN
        RAISE EXCEPTION 'an unresolved invitation cannot approve a device grant'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER api_key_device_grants_reject_pending_invitation
    BEFORE UPDATE OF status, approved_by_membership_id ON api_key_device_grants
    FOR EACH ROW EXECUTE FUNCTION api_key_device_grants_reject_pending_invitation()
    """
  end

  def down do
    execute "DROP TRIGGER api_key_device_grants_reject_pending_invitation ON api_key_device_grants"
    execute "DROP FUNCTION api_key_device_grants_reject_pending_invitation()"
    execute "DROP TRIGGER api_keys_reject_pending_invitation ON api_keys"
    execute "DROP FUNCTION api_keys_reject_pending_invitation()"

    execute "DROP TRIGGER account_memberships_revoke_invitation_credentials ON account_memberships"

    execute "DROP FUNCTION account_memberships_revoke_invitation_credentials()"
  end
end
