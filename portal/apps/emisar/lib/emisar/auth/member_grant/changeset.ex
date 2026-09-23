defmodule Emisar.Auth.MemberGrant.Changeset do
  use Emisar, :changeset
  alias Emisar.Auth.MemberGrant

  def create(token, member) do
    change(%MemberGrant{},
      user_token_id: token.id,
      account_id: member.account_id,
      membership_id: member.id
    )
    |> unique_constraint([:user_token_id, :account_id])
    |> foreign_key_constraint(:membership_id, name: :auth_member_grants_membership_fkey)
  end

  def transfer_session(%MemberGrant{} = grant, token) do
    change(grant, user_token_id: token.id)
    |> unique_constraint([:user_token_id, :account_id])
  end
end
