defmodule Emisar.Repo.Migrations.AllowEmailChangeAttemptScope do
  use Ecto.Migration

  # A Member can change its own sign-in email again; the codes that change sends
  # draw on their own durable issuance budget.
  def up do
    drop constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check)

    create constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check,
             check:
               "scope IN ('mfa_challenge', 'inbox_step_up', 'mfa_enrollment_issue', 'oidc_identity_step_up_issue', 'email_change_issue')"
           )
  end

  def down do
    execute "DELETE FROM auth_security_attempt_windows WHERE scope = 'email_change_issue'"

    drop constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check)

    create constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check,
             check:
               "scope IN ('mfa_challenge', 'inbox_step_up', 'mfa_enrollment_issue', 'oidc_identity_step_up_issue')"
           )
  end
end
