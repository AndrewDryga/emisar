defmodule Emisar.Auth.MemberGrant do
  @moduledoc "One session's exact workspace actor. Proof routes carry authority; roles remain on the Member."
  use Emisar, :schema

  schema "auth_member_grants" do
    belongs_to :user_token, Emisar.Auth.UserToken
    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :membership, Emisar.Accounts.Membership, where: [deleted_at: nil]
    has_many :routes, Emisar.Auth.MemberGrantRoute

    timestamps(updated_at: false)
  end
end
