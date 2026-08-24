defmodule Emisar.Repo.Migrations.BindLocalMfaProofToSession do
  @moduledoc """
  `mfa_verified_at` records the generic second-factor assurance present when a
  session was authenticated. For SSO that assurance belongs to the IdP, while a
  later Emisar TOTP proof belongs to the user's current local enrollment. One
  timestamp cannot distinguish those independent claims.

  Keep the authentication-time stamp and add the exact local enrollment epoch
  this session proved. Equality, rather than comparing wall-clock proof times,
  makes disable/re-enroll invalidation independent of clock skew between Portal
  nodes. Existing MFA-complete magic-link sessions that still satisfy the old
  timestamp check are bound to the user's current epoch; SSO stamps remain
  IdP-only.
  """
  use Ecto.Migration

  def up do
    alter table(:auth_user_tokens) do
      add :mfa_enrollment_verified_at, :utc_datetime_usec
    end

    execute """
    UPDATE auth_user_tokens AS token
    SET mfa_enrollment_verified_at = users.mfa_enabled_at
    FROM users
    WHERE token.user_id = users.id
      AND token.context = 'session'
      AND token.auth_method = 'magic_link'
      AND token.mfa_verified_at IS NOT NULL
      AND users.mfa_enabled_at IS NOT NULL
      AND token.mfa_verified_at >= users.mfa_enabled_at
    """

    create constraint(:auth_user_tokens, :local_mfa_proof_belongs_to_session,
             check:
               "mfa_enrollment_verified_at IS NULL OR " <>
                 "(context = 'session' AND auth_method IS NOT NULL AND " <>
                 "auth_method IN ('magic_link', 'sso'))"
           )
  end

  def down do
    drop constraint(:auth_user_tokens, :local_mfa_proof_belongs_to_session)

    alter table(:auth_user_tokens) do
      remove :mfa_enrollment_verified_at
    end
  end
end
