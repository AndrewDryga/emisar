defmodule Emisar.SSO.Authorizer do
  @moduledoc "Authorization for SSO identity-provider configuration + identity bindings."
  use Emisar.Auth.Authorizer
  alias Emisar.SSO.DirectoryGroupMember
  alias Emisar.SSO.GroupRoleMapping
  alias Emisar.SSO.IdentityProvider
  alias Emisar.SSO.LinkRequest
  alias Emisar.SSO.UserIdentity

  def manage_sso_permission, do: build(IdentityProvider, :manage)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_sso_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}) do
    case query_source(queryable) do
      :sso_identity_providers ->
        IdentityProvider.Query.by_account_id(queryable, account_id)

      :sso_user_identities ->
        UserIdentity.Query.by_account_id(queryable, account_id)

      :sso_directory_group_role_mappings ->
        GroupRoleMapping.Query.by_account_id(queryable, account_id)

      :sso_directory_group_members ->
        DirectoryGroupMember.Query.by_account_id(queryable, account_id)

      :sso_link_requests ->
        LinkRequest.Query.by_account_id(queryable, account_id)

      _ ->
        queryable
    end
  end

  def for_subject(queryable, _), do: queryable
end
