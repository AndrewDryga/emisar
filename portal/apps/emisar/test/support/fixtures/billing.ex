defmodule Emisar.Fixtures.Billing.Provider do
  @moduledoc false
  @behaviour Emisar.Billing.PaddleClient
  alias Emisar.Billing.PaddleClient.Stub
  alias Emisar.Config

  @impl true
  defdelegate create_customer(attrs), to: Stub
  @impl true
  defdelegate update_customer(attrs), to: Stub
  @impl true
  defdelegate list_customers(attrs), to: Stub
  @impl true
  defdelegate list_products(), to: Stub
  @impl true
  defdelegate create_billing_portal_session(attrs), to: Stub
  @impl true
  defdelegate list_transactions(attrs), to: Stub
  @impl true
  defdelegate get_transaction_invoice(id), to: Stub
  @impl true
  defdelegate construct_webhook_event(payload, signature, secret), to: Stub
  @impl true
  defdelegate update_subscription(id, attrs), to: Stub

  @impl true
  def create_checkout_session(attrs) do
    request(:create, attrs, fn store ->
      id = "txn_" <> Ecto.UUID.generate()

      transaction = %{
        "id" => id,
        "customer_id" => attrs.customer,
        "status" => "ready",
        "origin" => "api",
        "collection_mode" => "automatic",
        "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "custom_data" => attrs[:custom_data] || %{},
        "items" => [%{"price" => %{"id" => attrs.price_id}, "quantity" => attrs.quantity}],
        "checkout" => %{"url" => "https://checkout.example.test/?_ptxn=" <> id}
      }

      Agent.update(store, &put_in(&1, [:transactions, id], transaction))
      {:ok, transaction}
    end)
  end

  @impl true
  def bind_checkout_transaction(id, custom_data) do
    request(
      :bind,
      {id, custom_data},
      &update_transaction(&1, id, %{"custom_data" => custom_data}, ["draft", "ready"])
    )
  end

  @impl true
  def retrieve_transaction(id), do: request(:get_transaction, id, &fetch(&1, :transactions, id))

  @impl true
  def retrieve_subscription(id),
    do: request(:get_subscription, id, &fetch(&1, :subscriptions, id))

  @impl true
  def cancel_checkout_transaction(id) do
    request(
      :cancel_transaction,
      id,
      &update_transaction(&1, id, %{"status" => "canceled"}, [
        "draft",
        "ready",
        "billed",
        "canceled"
      ])
    )
  end

  @impl true
  def cancel_subscription(id) do
    request(:cancel_subscription, id, &cancel_stored_subscription(&1, id))
  end

  defp cancel_stored_subscription(store, id) do
    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.subscriptions, id) do
        {:ok, subscription} ->
          canceled = Map.put(subscription, "status", "canceled")
          {{:ok, canceled}, put_in(state, [:subscriptions, id], canceled)}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  @impl true
  def list_checkout_transactions(attrs) do
    request(:list_transactions, attrs, fn store ->
      rows = Agent.get(store, &Map.values(&1.transactions))

      rows =
        Enum.filter(rows, fn row ->
          row["customer_id"] == attrs[:customer] and
            (is_nil(attrs[:created_after]) or row["created_at"] >= attrs[:created_after]) and
            (is_nil(attrs[:after]) or row["id"] > attrs[:after])
        end)

      page = rows |> Enum.sort_by(& &1["id"]) |> Enum.take(attrs[:limit] || 30)
      next = if length(rows) > length(page), do: List.last(page)["id"]
      {:ok, %{transactions: page, next_after: next}}
    end)
  end

  @impl true
  def list_subscriptions(attrs) do
    request(:list_subscriptions, attrs, fn store ->
      rows = Agent.get(store, &Map.values(&1.subscriptions))
      {:ok, %{subscriptions: rows, next_after: nil}}
    end)
  end

  defp request(operation, args, fun) do
    store = Config.fetch_env!(:emisar, :billing_test_provider)
    owner = Agent.get(store, & &1.owner)
    send(owner, {:paddle, operation, args, self()})

    before_call =
      Config.get_env(:emisar, :billing_test_before_call, fn _operation, _args -> :ok end)

    before_call.(operation, args)
    result = fun.(store)

    after_call =
      Config.get_env(:emisar, :billing_test_after_call, fn _operation, _args, result -> result end)

    after_call.(operation, args, result)
  end

  defp fetch(store, kind, id) do
    case Agent.get(store, &Map.fetch(&1[kind], id)) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :not_found}
    end
  end

  defp update_transaction(store, id, attrs, statuses) do
    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.transactions, id) do
        {:ok, transaction} ->
          if transaction["status"] in statuses do
            updated = Map.merge(transaction, attrs)
            {{:ok, updated}, put_in(state, [:transactions, id], updated)}
          else
            {{:error, :transaction_not_mutable}, state}
          end

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end
end

defmodule Emisar.Fixtures.Billing do
  @moduledoc false
  alias Emisar.Billing
  alias Emisar.Billing.{CheckoutIntent, PaddleClient, SubscriptionRetirement}
  alias Emisar.{Config, Crypto, Repo}
  alias Emisar.Fixtures.Billing.Provider

  def deliver_event(event, event_id \\ "evt_" <> Ecto.UUID.generate()) do
    event = Map.put(event, "event_id", event_id)
    Billing.record_and_apply_event(event_id, Map.fetch!(event, "event_type"), event)
  end

  def delete_checkout_test_receipts(account_id) do
    prefix = "evt_checkout_#{account_id}_"
    Repo.query!("DELETE FROM paddle_processed_events WHERE left(id, length($1)) = $1", [prefix])
  end

  def start_provider do
    owner = self()

    store =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{owner: owner, transactions: %{}, subscriptions: %{}} end}
      )

    Config.put_override(:emisar, :billing_test_provider, store)
    Config.put_override(:emisar, :paddle_client, Provider)
    store
  end

  def set_transaction(id, attrs) do
    store = Config.fetch_env!(:emisar, :billing_test_provider)

    Agent.get_and_update(store, fn state ->
      updated = Map.merge(Map.fetch!(state.transactions, id), attrs)
      {updated, put_in(state, [:transactions, id], updated)}
    end)
  end

  def set_subscription(id, attrs) do
    store = Config.fetch_env!(:emisar, :billing_test_provider)

    Agent.get_and_update(store, fn state ->
      updated = Map.merge(Map.fetch!(state.subscriptions, id), attrs)
      {updated, put_in(state, [:subscriptions, id], updated)}
    end)
  end

  def complete_transaction(transaction_id, attrs \\ %{}) do
    {:ok, transaction} = PaddleClient.retrieve_transaction(transaction_id)
    id = "sub_" <> Ecto.UUID.generate()
    {:ok, defaults} = PaddleClient.Stub.retrieve_subscription(id)

    subscription =
      defaults
      |> Map.merge(%{
        "customer_id" => transaction["customer_id"],
        "custom_data" => transaction["custom_data"],
        "transaction_id" => transaction_id
      })
      |> Map.merge(attrs)

    set_transaction(transaction_id, %{"status" => "completed", "subscription_id" => id})
    store = Config.fetch_env!(:emisar, :billing_test_provider)
    Agent.update(store, &put_in(&1, [:subscriptions, id], subscription))
    subscription
  end

  def create_legacy_transaction(account, attrs \\ %{}) do
    {:ok, transaction} =
      PaddleClient.create_checkout_session(%{
        customer: account.paddle_customer_id,
        price_id: "pri_stub_team_month",
        quantity: 1
      })

    custom_data = %{
      "emisar_account_binding" => Crypto.paddle_account_binding(account.id, transaction["id"])
    }

    set_transaction(transaction["id"], Map.merge(%{"custom_data" => custom_data}, attrs))
  end

  def create_checkout_intent(account, attrs \\ %{}) do
    %{
      account_id: account.id,
      plan: :team,
      billing_interval: :month,
      customer_id: account.paddle_customer_id,
      price_id: "pri_stub_team_month",
      quantity: 1
    }
    |> Map.merge(Map.new(attrs))
    |> CheckoutIntent.Changeset.reserve()
    |> Repo.insert!()
  end

  def create_retirement(account, subscription) do
    {:ok, {_account_id, transaction_id}} =
      Crypto.verify_paddle_account_binding(subscription["custom_data"]["emisar_account_binding"])

    %{
      account_id: account.id,
      customer_id: subscription["customer_id"],
      transaction_id: transaction_id,
      subscription_id: subscription["id"],
      reason: :duplicate
    }
    |> SubscriptionRetirement.Changeset.enqueue()
    |> Repo.insert!()
  end

  def rewind_to_binding(intent) do
    intent |> Ecto.Changeset.change(state: :binding, checkout_url: nil) |> Repo.update!()
  end

  def confirm_retirement(retirement) do
    retirement |> SubscriptionRetirement.Changeset.confirm() |> Repo.update!()
  end

  def delete_recovery_rows(account_id) do
    account_id |> CheckoutIntent.Query.by_account_id() |> Repo.delete_all()
    account_id |> SubscriptionRetirement.Query.by_account_id() |> Repo.delete_all()
    :ok
  end
end
