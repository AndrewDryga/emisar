defmodule Emisar.Auth.MemberGrantRoute.Changeset do
  use Emisar, :changeset
  alias Emisar.Auth.MemberGrantRoute

  def personal(grant, proved_at, expires_at) do
    grant
    |> base(proved_at, expires_at)
    |> change(auth_method: :magic_link, direct: true)
  end

  def sso(grant, identity, direct?, mfa?, proved_at, expires_at) do
    grant
    |> base(proved_at, expires_at)
    |> change(
      auth_method: :sso,
      direct: direct?,
      user_identity_id: identity.id,
      issuer: identity.provider.issuer,
      provider_identifier: identity.provider_identifier,
      idp_mfa_verified_at: if(mfa?, do: proved_at)
    )
  end

  defp base(grant, proved_at, expires_at) do
    change(%MemberGrantRoute{},
      member_grant_id: grant.id,
      account_id: grant.account_id,
      membership_id: grant.membership_id,
      proved_at: proved_at,
      expires_at: expires_at
    )
    |> foreign_key_constraint(:member_grant_id, name: :auth_member_grant_routes_grant_fkey)
    |> foreign_key_constraint(:user_identity_id, name: :auth_member_grant_routes_identity_fkey)
    |> check_constraint(:auth_method, name: :auth_member_grant_routes_proof_check)
  end
end
