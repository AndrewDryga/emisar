defmodule Emisar.Accounts.Authorizer do
  @moduledoc """
  Account, user, and membership authorization. The owner role is the
  only one that can modify ownership; admins can manage team but not
  promote anyone past their own level.
  """
  use Emisar.Auth.Authorizer
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Users

  # -- Catalogue -------------------------------------------------------

  def manage_own_account_permission, do: build(Account, :manage_own)
  def view_own_account_permission, do: build(Account, :view_own)
  def manage_team_permission, do: build(Membership, :manage_team)
  # Owner-only: required to grant, revoke, or modify the owner role
  # itself. Admins hold manage_team but not this.
  def manage_owners_permission, do: build(Membership, :manage_owners)
  def invite_member_permission, do: build(Membership, :invite)
  def edit_own_profile_permission, do: build(Users.User, :edit_self)
  # Held by owners only — required to flip account-wide security knobs
  # (require_mfa, etc.).
  def manage_security_settings_permission, do: build(Account, :manage_security)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(:owner),
    do: [
      manage_own_account_permission(),
      view_own_account_permission(),
      manage_team_permission(),
      manage_owners_permission(),
      invite_member_permission(),
      manage_security_settings_permission(),
      edit_own_profile_permission()
    ]

  def list_permissions_for_role(:admin),
    do: [
      manage_own_account_permission(),
      view_own_account_permission(),
      manage_team_permission(),
      invite_member_permission(),
      manage_security_settings_permission(),
      edit_own_profile_permission()
    ]

  # billing_manager gets the same account floor as operator/viewer — enough
  # to sign in, see the account, and edit their own profile; team management
  # and security settings stay owner/admin.
  def list_permissions_for_role(role) when role in [:billing_manager, :operator, :viewer],
    do: [view_own_account_permission(), edit_own_profile_permission()]

  def list_permissions_for_role(:api_client),
    do: [view_own_account_permission()]

  def list_permissions_for_role(_), do: []

  # -- Subject scoping -------------------------------------------------

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %Account{id: account_id}}) do
    case query_source(queryable) do
      :accounts -> Account.Query.by_id(queryable, account_id)
      :memberships -> Membership.Query.by_account_id(queryable, account_id)
      :users -> queryable
      _ -> queryable
    end
  end

  def for_subject(queryable, _), do: queryable
end
