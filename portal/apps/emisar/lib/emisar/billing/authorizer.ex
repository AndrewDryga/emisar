defmodule Emisar.Billing.Authorizer do
  @moduledoc "Authorization for the billing surface."
  use Emisar.Auth.Authorizer
  alias Emisar.Billing.Subscription

  def manage_billing_permission, do: build(Subscription, :manage)

  # Reading the ledger — the invoice list and its PDFs. A tier of its own between
  # manage and view: an admin runs the account and answers for what it spends, so
  # they read the invoices without being able to change the plan or the card,
  # while an operator drives infrastructure and has no business in either.
  def view_invoices_permission, do: build(Subscription, :view_invoices)

  def view_billing_permission, do: build(Subscription, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(:owner),
    do: [manage_billing_permission(), view_invoices_permission(), view_billing_permission()]

  def list_permissions_for_role(:admin),
    do: [view_invoices_permission(), view_billing_permission()]

  # The finance seat: full billing control is this role's entire job.
  def list_permissions_for_role(:billing_manager),
    do: [manage_billing_permission(), view_invoices_permission(), view_billing_permission()]

  # The plan and its limits are an operational fact every member works against;
  # the money behind them is not theirs to read.
  def list_permissions_for_role(role) when role in [:operator, :viewer],
    do: [view_billing_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Subscription.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: Subscription.Query.none(queryable)
end
