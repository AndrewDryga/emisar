defmodule Emisar.Billing.Authorizer do
  @moduledoc "Authorization for the billing surface."
  use Emisar.Auth.Authorizer

  alias Emisar.Billing.Subscription

  def manage_billing_permission, do: build(Subscription, :manage)
  def view_billing_permission, do: build(Subscription, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(:owner),
    do: [manage_billing_permission(), view_billing_permission()]

  def list_permissions_for_role(:admin),
    do: [view_billing_permission()]

  def list_permissions_for_role(role) when role in [:operator, :viewer],
    do: [view_billing_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Subscription.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
