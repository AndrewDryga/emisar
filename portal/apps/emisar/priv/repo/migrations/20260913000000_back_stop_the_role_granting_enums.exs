defmodule Emisar.Repo.Migrations.BackStopTheRoleGrantingEnums do
  use Ecto.Migration

  # 20260816000002 added DB CHECK backstops for the security-relevant enums and
  # covered `account_memberships.role` — but not the two SSO columns that DECIDE
  # that role. A directory push writes them, and they are the crown-jewel values
  # in the product: an invalid one is either a crash on load or, worse, a role
  # string nothing in the app can reason about.
  #
  # Both mirror `Emisar.Auth.Role.all/0`. Extending the role set needs a new
  # migration replacing these CHECKs in the same change, exactly as 20260816000002
  # says for the enums it covered.
  #
  # Added plainly rather than NOT VALID + VALIDATE: both tables are per-account
  # SSO configuration, a handful of rows each, so the scan and its ACCESS
  # EXCLUSIVE lock are instant. A large table would need the two-step form (see
  # .agent/kb/rules/elixir-migrations-frozen.md).

  @roles "('owner', 'admin', 'billing_manager', 'operator', 'viewer')"

  def change do
    create constraint(:sso_identity_providers, :sso_identity_providers_default_role_check,
             check: "default_role IN #{@roles}"
           )

    create constraint(
             :sso_directory_group_role_mappings,
             :sso_directory_group_role_mappings_role_check,
             check: "role IN #{@roles}"
           )
  end
end
