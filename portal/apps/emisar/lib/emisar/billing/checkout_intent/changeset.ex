defmodule Emisar.Billing.CheckoutIntent.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.CheckoutIntent

  @facts ~w[account_id plan billing_interval customer_id price_id quantity]a

  def reserve(attrs) do
    %CheckoutIntent{}
    |> cast(attrs, @facts)
    |> put_change(:state, :creating)
    |> validate_required(@facts)
    |> validate_number(:quantity, greater_than: 0)
    |> database_constraints()
  end

  def capture(%CheckoutIntent{state: :creating} = intent, transaction_id) do
    intent
    |> change(transaction_id: transaction_id, state: :binding, failure_category: nil)
    |> validate_required([:transaction_id])
    |> database_constraints()
  end

  def capture(%CheckoutIntent{} = intent, _id), do: invalid_transition(intent)

  def payable(%CheckoutIntent{state: state} = intent, url) when state in [:binding, :payable] do
    intent
    |> change(checkout_url: url, state: :payable, failure_category: nil)
    |> validate_required([:checkout_url])
    |> database_constraints()
  end

  def payable(%CheckoutIntent{} = intent, _url), do: invalid_transition(intent)

  def retire(%CheckoutIntent{state: state} = intent)
      when state in [:binding, :payable, :retiring_transaction],
      do: intent |> change(state: :retiring_transaction) |> database_constraints()

  def retire(%CheckoutIntent{} = intent), do: invalid_transition(intent)

  def reconcile_payment(%CheckoutIntent{state: state} = intent)
      when state in [:binding, :payable, :retiring_transaction, :payment_reconciling] do
    intent
    |> change(state: :payment_reconciling, failure_category: nil)
    |> database_constraints()
  end

  def reconcile_payment(%CheckoutIntent{} = intent), do: invalid_transition(intent)

  def subscribe(%CheckoutIntent{state: :payment_reconciling} = intent),
    do: intent |> change(state: :subscribed, failure_category: nil) |> database_constraints()

  def subscribe(%CheckoutIntent{} = intent), do: invalid_transition(intent)

  def cancel(%CheckoutIntent{state: state} = intent)
      when state in [:binding, :payable, :retiring_transaction, :payment_reconciling],
      do: intent |> change(state: :canceled, failure_category: nil) |> database_constraints()

  def cancel(%CheckoutIntent{} = intent), do: invalid_transition(intent)

  def fail(%CheckoutIntent{state: :creating} = intent),
    do: intent |> change(state: :failed, failure_category: nil) |> database_constraints()

  def fail(%CheckoutIntent{} = intent), do: invalid_transition(intent)

  def record_failure(%CheckoutIntent{} = intent, category),
    do: change(intent, failure_category: category)

  defp invalid_transition(intent),
    do: intent |> change() |> add_error(:state, "has already changed")

  defp database_constraints(changeset) do
    changeset
    |> unique_constraint(:account_id, name: :billing_checkout_intents_current_account_index)
    |> unique_constraint(:transaction_id)
    |> check_constraint(:state, name: :billing_checkout_intents_shape)
  end
end
