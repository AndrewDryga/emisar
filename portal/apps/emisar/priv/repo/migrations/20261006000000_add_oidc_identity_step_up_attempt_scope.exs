defmodule Emisar.Repo.Migrations.AddOidcIdentityStepUpAttemptScope do
  use Ecto.Migration

  def up do
    drop constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check)

    create constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check,
             check:
               "scope IN ('mfa_challenge', 'inbox_step_up', 'email_change_issue', 'mfa_enrollment_issue', 'oidc_identity_step_up_issue')"
           )
  end

  def down do
    execute "DELETE FROM auth_security_attempt_windows WHERE scope = 'oidc_identity_step_up_issue'"

    drop constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check)

    create constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check,
             check:
               "scope IN ('mfa_challenge', 'inbox_step_up', 'email_change_issue', 'mfa_enrollment_issue')"
           )
  end
end
