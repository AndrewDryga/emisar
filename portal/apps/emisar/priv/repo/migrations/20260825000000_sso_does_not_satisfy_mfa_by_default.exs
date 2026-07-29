defmodule Emisar.Repo.Migrations.SsoDoesNotSatisfyMfaByDefault do
  @moduledoc """
  `satisfies_mfa` shipped defaulting to TRUE, which means a brand-new connection
  told emisar to accept the provider's word that a second factor happened. A
  password-only OIDC server therefore satisfied an account's 2FA requirement by
  default — the console's own field warns "this provider must enforce MFA itself,
  otherwise members who sign in through it bypass your 2FA requirement", and then
  pre-ticked it.

  The default flips to false: trusting someone else's MFA is a claim an operator
  should make deliberately, not one they inherit.

  Existing rows flip too. The column has only ever had this default, so a `true`
  out there is far more likely to be the default nobody looked at than a
  considered decision, and the failure mode of leaving it is a silent MFA bypass.
  Flipping costs those members one TOTP enrolment (the account funnels them to
  their profile); leaving it costs the account its second factor. An operator who
  did mean it re-ticks the box on the connection.
  """
  use Ecto.Migration

  def up do
    alter table(:sso_identity_providers) do
      modify :satisfies_mfa, :boolean, null: false, default: false
    end

    execute "UPDATE sso_identity_providers SET satisfies_mfa = false WHERE satisfies_mfa = true"
  end

  def down do
    alter table(:sso_identity_providers) do
      modify :satisfies_mfa, :boolean, null: false, default: true
    end
  end
end
