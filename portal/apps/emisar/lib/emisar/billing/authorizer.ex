defmodule Emisar.Billing.Authorizer do
  @moduledoc "Authorization for the billing surface."
  use Emisar.Auth.Authorizer
  alias Emisar.Billing.Subscription

  def manage_billing_permission, do: build(Subscription, :manage)

  # Reading the ledger — the invoice list and its PDFs. A tier of its own between
  # manage and view: the roles that answer for what the account spends read the
  # invoices, while an operator drives infrastructure and has no business there.
  def view_invoices_permission, do: build(Subscription, :view_invoices)

  def view_billing_permission, do: build(Subscription, :view)

  # An admin runs the account, so they run its money too — founder's call. The
  # finance seat holds the same billing grants and nothing else, which is now its
  # entire point: a least-privilege alternative to handing out admin.
  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin, :billing_manager],
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
