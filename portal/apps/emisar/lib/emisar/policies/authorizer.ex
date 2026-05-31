defmodule Emisar.Policies.Authorizer do
  @moduledoc "Authorization for policy bundles."
  use Emisar.Auth.Authorizer

  alias Emisar.Policies.Policy

  def manage_policies_permission, do: build(Policy, :manage)
  def view_policies_permission, do: build(Policy, :view)
  def evaluate_policy_permission, do: build(Policy, :evaluate)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_policies_permission(), view_policies_permission(), evaluate_policy_permission()]

  def list_permissions_for_role(role) when role in [:operator, :viewer],
    do: [view_policies_permission(), evaluate_policy_permission()]

  def list_permissions_for_role(:api_client),
    do: [evaluate_policy_permission()]

  def list_permissions_for_role(:system),
    do: [manage_policies_permission(), view_policies_permission(), evaluate_policy_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Policy.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
