defmodule Emisar.SSO.UserIdentity do
  @moduledoc """
  Binds an external identity to a user: `provider_identifier` is the OIDC
  `sub`, and `(provider, provider_identifier)` is the only stable key — an
  OIDC login is never matched by email. A user may hold many identities.
  `claims` keeps identity + forensic claims (sub/email/name/hd/amr/acr/
  auth_time); never the IdP's OAuth tokens.

  `provider_identifier_retired_at` disables an admin-approved OIDC binding
  without deleting the SCIM lifecycle row. The historical value remains on the
  row, while active-binding uniqueness releases authentication ownership so its
  current provider-asserted owner may claim it. `created_by` records who granted
  the current OIDC binding; `provisioned_via` records the row's origin (OIDC JIT
  login, SCIM directory sync, or an admin approving a `:manual` link request).
  For a SCIM identity, `scim_external_id` is the IdP's `externalId` (equal to
  `provider_identifier` when identifier-matching is configured — decision 4)
  and `scim_active` is its SCIM lifecycle state, distinct from the membership's
  `disabled_at`. SCIM `DELETE /Users` sets `scim_deleted_at` and retires the
  independent OIDC binding: the wire resource disappears while the shared row,
  person, externalId reservation, and one-identity slot remain intact. An exact
  later `externalId` create clears only the SCIM tombstone.
  """
  use Emisar, :schema

  @created_by [:provider, :admin, :user]
  @provisioned_via [:oidc_jit, :oidc_link, :scim, :manual]

  schema "sso_user_identities" do
    field :provider_identifier, :string
    field :provider_identifier_retired_at, :utc_datetime_usec
    field :claims, :map, default: %{}
    field :created_by, Ecto.Enum, values: @created_by

    field :scim_external_id, :string
    field :provisioned_via, Ecto.Enum, values: @provisioned_via
    field :scim_active, :boolean, default: true
    field :scim_deleted_at, :utc_datetime_usec

    field :last_seen_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :provider, Emisar.SSO.IdentityProvider, where: [deleted_at: nil]
    belongs_to :user, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end
