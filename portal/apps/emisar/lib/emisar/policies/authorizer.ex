defmodule Emisar.Policies.Authorizer do
  @moduledoc "Authorization for policy bundles."
  use Emisar.Auth.Authorizer

  alias Emisar.Policies.Policy

  def manage_policies_permission, do: build(Policy, :manage)
  def view_policies_permission, do: build(Policy, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_policies_permission(), view_policies_permission()]

  def list_permissions_for_role(role) when role in [:operator, :viewer],
    do: [view_policies_permission()]

  def list_permissions_for_role(:api_client), do: []

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Policy.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
