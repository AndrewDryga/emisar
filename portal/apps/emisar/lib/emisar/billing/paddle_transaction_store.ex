defmodule Emisar.Billing.PaddleClient.Stub.TransactionStore do
  @moduledoc false
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def create(attrs) do
    id = "txn_stub_" <> Ecto.UUID.generate()

    transaction = %{
      "id" => id,
      "customer_id" => attrs[:customer],
      "origin" => "api",
      "collection_mode" => "automatic",
      "status" => "ready",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "custom_data" => attrs[:custom_data] || %{},
      "items" => [%{"price" => %{"id" => attrs[:price_id]}, "quantity" => attrs[:quantity] || 1}],
      "checkout" => %{"url" => "https://stub.paddle.test/checkout/" <> id}
    }

    Agent.update(__MODULE__, &Map.put(&1, id, transaction))
    {:ok, transaction}
  end

  def fetch(id), do: Agent.get(__MODULE__, &Map.fetch(&1, id))

  def bind(id, custom_data), do: update(id, %{"custom_data" => custom_data}, ["draft", "ready"])

  def cancel(id),
    do: update(id, %{"status" => "canceled"}, ["draft", "ready", "billed", "canceled"])

  defp update(id, attrs, statuses) do
    Agent.get_and_update(__MODULE__, fn transactions ->
      case Map.fetch(transactions, id) do
        {:ok, transaction} ->
          if transaction["status"] in statuses do
            updated = Map.merge(transaction, attrs)
            {{:ok, updated}, Map.put(transactions, id, updated)}
          else
            {{:error, :transaction_not_mutable}, transactions}
          end

        :error ->
          {{:error, :not_found}, transactions}
      end
    end)
  end

  def list(attrs) do
    transactions =
      Agent.get(__MODULE__, &Map.values/1)
      |> Enum.filter(fn transaction ->
        transaction["customer_id"] == attrs[:customer] and
          (is_nil(attrs[:created_after]) or transaction["created_at"] >= attrs[:created_after]) and
          (is_nil(attrs[:after]) or transaction["id"] > attrs[:after])
      end)
      |> Enum.sort_by(& &1["id"])

    page = Enum.take(transactions, min(attrs[:limit] || 30, 30))
    next = if length(transactions) > length(page), do: List.last(page)["id"]
    {:ok, %{transactions: page, next_after: next}}
  end
end
