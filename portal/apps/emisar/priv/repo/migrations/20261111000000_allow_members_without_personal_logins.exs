defmodule Emisar.Repo.Migrations.AllowMembersWithoutPersonalLogins do
  use Ecto.Migration

  # A workspace Member may exist without a personal login. Such a Member signs
  # in only through its workspace SSO identity, so a bearer without a User is
  # an SSO session that carries no personal or local-factor proof. The live
  # partial unique index on (account_id, user_id) keeps NULLs distinct.
  #
  # The check does not require user_identity_id: that FK is ON DELETE SET NULL,
  # so requiring it would make deleting an account or seat fail while a
  # member-only bearer exists. Such a bearer keeps no grant and grants nothing.
  def up do
    execute "ALTER TABLE account_memberships ALTER COLUMN user_id DROP NOT NULL"
    execute "ALTER TABLE auth_user_tokens ALTER COLUMN user_id DROP NOT NULL"

    create constraint(:auth_user_tokens, :auth_user_tokens_member_only_session_check,
             check: """
             user_id IS NOT NULL OR (
               context = 'session' AND auth_method = 'sso'
               AND personal_proved_at IS NULL AND mfa_enrollment_verified_at IS NULL
             )
             """
           )
  end

  def down do
    drop constraint(:auth_user_tokens, :auth_user_tokens_member_only_session_check)
    execute "DELETE FROM auth_user_tokens WHERE user_id IS NULL"
    execute "ALTER TABLE auth_user_tokens ALTER COLUMN user_id SET NOT NULL"
    execute "ALTER TABLE account_memberships ALTER COLUMN user_id SET NOT NULL"
  end
end
