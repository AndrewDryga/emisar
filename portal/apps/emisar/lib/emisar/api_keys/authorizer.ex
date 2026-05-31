defmodule Emisar.ApiKeys.Authorizer do
  @moduledoc "Authorization for API keys (LLM / programmatic access)."
  use Emisar.Auth.Authorizer

  alias Emisar.ApiKeys.ApiKey

  def manage_api_keys_permission, do: build(ApiKey, :manage)
  def view_api_keys_permission, do: build(ApiKey, :view)
  def issue_quick_key_permission, do: build(ApiKey, :issue_quick)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_api_keys_permission(), view_api_keys_permission(), issue_quick_key_permission()]

  def list_permissions_for_role(:operator),
    do: [view_api_keys_permission(), issue_quick_key_permission()]

  def list_permissions_for_role(:viewer),
    do: [view_api_keys_permission()]

  def list_permissions_for_role(:system),
    do: [manage_api_keys_permission(), view_api_keys_permission(), issue_quick_key_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: ApiKey.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
