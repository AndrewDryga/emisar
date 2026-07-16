defmodule Emisar.SSO.UserIdentity do
  @moduledoc """
  Binds an external identity to a user: `provider_identifier` is the OIDC
  `sub`, and `(provider, provider_identifier)` is the only stable key — an
  OIDC login is never matched by email. A user may hold many identities.
  `claims` keeps identity + forensic claims (sub/email/name/hd/amr/acr/
  auth_time); never the IdP's OAuth tokens.

  `provisioned_via` records who created the binding (OIDC JIT login, SCIM
  directory sync, or an admin approving a `:manual` link request). For a SCIM
  identity, `scim_external_id` is the IdP's
  `externalId` (equal to `provider_identifier` when identifier-matching is
  configured — decision 4) and `scim_active` is its SCIM lifecycle state,
  distinct from the membership's `disabled_at`.
  """
  use Emisar, :schema

  @created_by [:provider, :admin]
  @provisioned_via [:oidc_jit, :scim, :manual]

  schema "sso_user_identities" do
    field :provider_identifier, :string
    field :claims, :map, default: %{}
    field :created_by, Ecto.Enum, values: @created_by

    field :scim_external_id, :string
    field :provisioned_via, Ecto.Enum, values: @provisioned_via
    field :scim_active, :boolean, default: true

    field :last_seen_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]
    belongs_to :user, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end
