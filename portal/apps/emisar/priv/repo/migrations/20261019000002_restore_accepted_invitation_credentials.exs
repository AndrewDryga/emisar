defmodule Emisar.Repo.Migrations.RestoreAcceptedInvitationCredentials do
  use Ecto.Migration

  @stage_table "accepted_invitation_memberships_20261019"

  def up do
    execute(fn -> restore!(repo()) end)

    execute "DROP TRIGGER api_key_device_grants_reject_pending_invitation ON api_key_device_grants"
    execute "DROP FUNCTION api_key_device_grants_reject_pending_invitation()"
    execute "DROP TRIGGER api_keys_reject_pending_invitation ON api_keys"
    execute "DROP FUNCTION api_keys_reject_pending_invitation()"

    execute "DROP TRIGGER account_memberships_revoke_invitation_credentials ON account_memberships"

    execute "DROP FUNCTION account_memberships_revoke_invitation_credentials()"
  end

  def down do
    raise "the invitation credential repair cannot be reversed safely"
  end

  @doc false
  def restore!(repo) do
    repo.query!("""
    UPDATE account_memberships AS membership
    SET invitation_accepted_at = staged.invitation_accepted_at
    FROM #{@stage_table} AS staged
    WHERE membership.id = staged.membership_id
    """)

    repo.query!("DROP TABLE #{@stage_table}")
  end
end
