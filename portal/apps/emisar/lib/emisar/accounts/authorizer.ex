defmodule Emisar.Accounts.Authorizer do
  @moduledoc """
  Account, user, and membership authorization. The owner role is the
  only one that can modify ownership; admins can manage team but not
  promote anyone past their own level.
  """
  use Emisar.Auth.Authorizer
  alias Emisar.Accounts.{Account, Membership}

  # -- Catalogue -------------------------------------------------------

  def manage_own_account_permission, do: build(Account, :manage_own)
  def view_own_account_permission, do: build(Account, :view_own)
  def manage_team_permission, do: build(Membership, :manage_team)
  # Owner-only: required to grant, revoke, or modify the owner role
  # itself. Admins hold manage_team but not this.
  def manage_owners_permission, do: build(Membership, :manage_owners)
  def invite_member_permission, do: build(Membership, :invite)
  # Held by owners and admins — required to flip account-wide security knobs.
  def manage_security_settings_permission, do: build(Account, :manage_security)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(:owner),
    do: [
      manage_own_account_permission(),
      view_own_account_permission(),
      manage_team_permission(),
      manage_owners_permission(),
      invite_member_permission(),
      manage_security_settings_permission()
    ]

  def list_permissions_for_role(:admin),
    do: [
      manage_own_account_permission(),
      view_own_account_permission(),
      manage_team_permission(),
      invite_member_permission(),
      manage_security_settings_permission()
    ]

  # billing_manager gets the same account floor as operator/viewer — enough
  # to sign in and see the account; team management and security settings
  # stay owner/admin. Editing your own profile is not permission-gated at
  # all: self-service authorization is the `%Subject{actor: ...}` identity
  # match, so no role carries a permission for it.
  def list_permissions_for_role(role) when role in [:billing_manager, :operator, :viewer],
    do: [view_own_account_permission()]

  def list_permissions_for_role(:api_client),
    do: [view_own_account_permission()]

  def list_permissions_for_role(_), do: []

  # -- Subject scoping -------------------------------------------------

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %Account{id: account_id}}) do
    case query_source(queryable) do
      :accounts -> Account.Query.by_id(queryable, account_id)
      :account_memberships -> Membership.Query.by_account_id(queryable, account_id)
      _ -> Account.Query.none(queryable)
    end
  end

  def for_subject(queryable, _), do: Account.Query.none(queryable)
end
