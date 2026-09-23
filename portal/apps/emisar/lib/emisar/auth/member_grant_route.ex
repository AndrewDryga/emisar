defmodule Emisar.Auth.MemberGrantRoute do
  @moduledoc "An independently aged personal, direct SSO or inferred SSO proof for one exact Member."
  use Emisar, :schema

  schema "auth_member_grant_routes" do
    field :auth_method, Ecto.Enum, values: [:magic_link, :sso]
    field :issuer, :string
    field :provider_identifier, :string
    field :direct, :boolean
    field :proved_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :idp_mfa_verified_at, :utc_datetime_usec

    belongs_to :member_grant, Emisar.Auth.MemberGrant
    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :membership, Emisar.Accounts.Membership, where: [deleted_at: nil]
    belongs_to :user_identity, Emisar.SSO.UserIdentity, where: [deleted_at: nil]

    timestamps(updated_at: false)
  end
end
