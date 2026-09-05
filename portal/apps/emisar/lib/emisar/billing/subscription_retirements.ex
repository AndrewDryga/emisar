defmodule Emisar.Billing.SubscriptionRetirements do
  @moduledoc false
  alias Ecto.Multi
  alias Emisar.{Accounts, Crypto, Repo}
  alias Emisar.Billing.{CheckoutIntent, Checkouts, PaddleClient}
  alias Emisar.Billing.{Subscription, SubscriptionRetirement}

  @known_statuses ~w[active trialing past_due paused canceled]

  # Internal provider proof. Customer membership or an intent UUID alone never
  # authorizes cancellation, including when several accounts share a customer.
  def verify_candidate(data, opts) when is_map(data) do
    with {:ok, {account_id, transaction_id}} <- verified_binding(data),
         true <- valid_id?(data["id"], "sub_") and valid_id?(transaction_id, "txn_"),
         true <- event_matches?(transaction_id, opts),
         {:ok, transaction} <- PaddleClient.retrieve_transaction(transaction_id),
         :ok <- verify_link(data, transaction, account_id, transaction_id),
         {:ok, subscription} <- PaddleClient.retrieve_subscription(data["id"]),
         :ok <-
           verify_subscription(
             subscription,
             account_id,
             transaction_id,
             data["id"],
             data["customer_id"]
           ) do
      {:ok,
       %{
         account_id: account_id,
         customer_id: data["customer_id"],
         transaction_id: transaction_id,
         subscription_id: data["id"],
         subscription: subscription
       }}
    else
      _unproven -> {:error, :invalid_subscription_account_binding}
    end
  end

  def verify_candidate(_data, _opts), do: {:error, :invalid_subscription_account_binding}

  defp verify_link(data, transaction, account_id, transaction_id) when is_map(transaction) do
    valid? =
      transaction["id"] == transaction_id and transaction["subscription_id"] == data["id"] and
        transaction["customer_id"] == data["customer_id"] and
        valid_id?(data["customer_id"], "ctm_") and
        transaction["status"] in ["paid", "completed"] and
        verified_binding(transaction) == {:ok, {account_id, transaction_id}}

    intent = transaction_id |> CheckoutIntent.Query.by_transaction_id() |> Repo.peek()

    cond do
      not valid? -> {:error, :invalid_subscription_account_binding}
      is_nil(intent) -> :ok
      intent.account_id != account_id -> {:error, :invalid_subscription_account_binding}
      true -> Checkouts.verify_transaction(intent, transaction)
    end
  end

  defp verify_link(_data, _transaction, _account_id, _transaction_id),
    do: {:error, :invalid_subscription_account_binding}

  defp verify_subscription(data, account_id, transaction_id, subscription_id, customer_id)
       when is_map(data) do
    if data["id"] == subscription_id and data["customer_id"] == customer_id and
         data["status"] in @known_statuses and
         verified_binding(data) == {:ok, {account_id, transaction_id}},
       do: :ok,
       else: {:error, :invalid_subscription_account_binding}
  end

  defp verify_subscription(_data, _account_id, _transaction_id, _subscription_id, _customer_id),
    do: {:error, :invalid_subscription_account_binding}

  defp event_matches?(transaction_id, opts) do
    case Keyword.get(opts, :transaction_id) do
      nil -> true
      id -> id == transaction_id
    end
  end

  defp verified_binding(%{"custom_data" => %{"emisar_account_binding" => token}}),
    do: Crypto.verify_paddle_account_binding(token)

  defp verified_binding(_data), do: {:error, :invalid}

  defp valid_id?(id, prefix) when is_binary(id) do
    String.starts_with?(id, prefix) and byte_size(id) > byte_size(prefix) and byte_size(id) <= 128 and
      Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)
  end

  defp valid_id?(_id, _prefix), do: false

  # Internal: the caller holds account -> subscription locks and has verified proof.
  def enqueue(proof, reason, canonical_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case find(proof.subscription_id, repo: repo) do
      nil ->
        proof
        |> Map.take([:account_id, :customer_id, :transaction_id, :subscription_id])
        |> Map.merge(%{reason: reason, canonical_subscription_id: canonical_id})
        |> SubscriptionRetirement.Changeset.enqueue()
        |> repo.insert()

      retirement ->
        {:ok, retirement}
    end
  end

  # Internal: completed IDs are deliberately included; late receipts cannot adopt them.
  def find(subscription_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    subscription_id |> SubscriptionRetirement.Query.by_subscription_id() |> repo.peek()
  end

  def recover(%SubscriptionRetirement{state: :confirmed} = retirement), do: {:ok, retirement}

  def recover(%SubscriptionRetirement{} = retirement) do
    with {:ok, subscription} <- PaddleClient.retrieve_subscription(retirement.subscription_id),
         :ok <-
           verify_subscription(
             subscription,
             retirement.account_id,
             retirement.transaction_id,
             retirement.subscription_id,
             retirement.customer_id
           ),
         {:ok, _canceled} <- cancel_unless_canceled(subscription) do
      update(retirement, &SubscriptionRetirement.Changeset.confirm/1)
    else
      _unconfirmed ->
        _result =
          update(
            retirement,
            &SubscriptionRetirement.Changeset.record_failure(&1, :provider_unavailable)
          )

        {:error, :subscription_retirement_pending}
    end
  end

  defp cancel_unless_canceled(%{"status" => "canceled"} = subscription), do: {:ok, subscription}

  defp cancel_unless_canceled(%{"id" => id}) do
    case PaddleClient.cancel_subscription(id) do
      {:ok, %{"id" => ^id, "status" => "canceled"} = subscription} -> {:ok, subscription}
      _unconfirmed -> {:error, :cancellation_not_confirmed}
    end
  end

  defp update(retirement, changeset_fun) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(retirement.account_id,
             repo: repo,
             include_deleted?: true
           ) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:ok, nil}
      end
    end)
    |> Multi.run(:retirement, fn repo, _changes ->
      Subscription.Query.all()
      |> Subscription.Query.by_account_id(retirement.account_id)
      |> Subscription.Query.lock_for_update()
      |> repo.peek()

      current =
        retirement.id
        |> SubscriptionRetirement.Query.by_id()
        |> SubscriptionRetirement.Query.lock_for_update()
        |> repo.peek()

      if current.state == :confirmed,
        do: {:ok, current},
        else: current |> changeset_fun.() |> repo.update()
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{retirement: retirement}} -> {:ok, retirement}
      error -> error
    end
  end

  # Internal: prepare cleanup before Accounts' final DB-only closure transaction.
  def cancel_for_close(account_id) do
    rows =
      account_id
      |> SubscriptionRetirement.Query.by_account_id()
      |> SubscriptionRetirement.Query.pending()
      |> SubscriptionRetirement.Query.limit_to(101)
      |> Repo.all()

    if length(rows) > 100 do
      {:error, :subscription_retirement_pending}
    else
      Enum.reduce_while(rows, :ok, fn row, :ok ->
        case recover(row) do
          {:ok, _retirement} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end
end
