defmodule Emisar.Billing.PaddleClient do
  @moduledoc """
  Behaviour wrapping the Paddle API surface we use. Concrete
  implementation lives in `PaddleClient.Live`; tests use
  `PaddleClient.Stub`.

  We intentionally call out only the operations we need —
  customer creation, transaction (checkout) creation, billing-portal
  session creation, subscription read, product-catalog read, webhook
  signature verify. Everything else can be added when a legitimate
  need surfaces.
  """

  @callback create_customer(map()) :: {:ok, map()} | {:error, term()}
  @callback update_customer(map()) :: {:ok, map()} | {:error, term()}
  @callback list_customers(map()) :: {:ok, [map()]} | {:error, term()}
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback bind_checkout_transaction(String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback cancel_checkout_transaction(String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_checkout_transactions(keyword()) ::
              {:ok, %{transactions: [map()], next_after: String.t() | nil}} | {:error, term()}
  @callback create_billing_portal_session(map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_transaction(String.t()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  @callback update_subscription(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_subscriptions(keyword()) ::
              {:ok, %{subscriptions: [map()], next_after: String.t() | nil}} | {:error, term()}
  @callback cancel_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_products() :: {:ok, [map()]} | {:error, term()}
  @callback list_transactions(map()) :: {:ok, [map()]} | {:error, term()}
  @callback get_transaction_invoice(String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback construct_webhook_event(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}

  defp client, do: Emisar.Config.fetch_env!(:emisar, :paddle_client)

  def create_customer(attrs), do: client().create_customer(attrs)
  def update_customer(attrs), do: client().update_customer(attrs)
  def list_customers(attrs), do: client().list_customers(attrs)
  def create_checkout_session(attrs), do: client().create_checkout_session(attrs)
  def bind_checkout_transaction(id, binding), do: client().bind_checkout_transaction(id, binding)
  def cancel_checkout_transaction(id), do: client().cancel_checkout_transaction(id)
  def list_checkout_transactions(attrs), do: client().list_checkout_transactions(attrs)
  def create_billing_portal_session(attrs), do: client().create_billing_portal_session(attrs)
  def retrieve_transaction(id), do: client().retrieve_transaction(id)
  def retrieve_subscription(id), do: client().retrieve_subscription(id)
  def update_subscription(id, attrs), do: client().update_subscription(id, attrs)
  def list_subscriptions(attrs), do: client().list_subscriptions(attrs)
  def cancel_subscription(id), do: client().cancel_subscription(id)
  def list_products, do: client().list_products()
  def list_transactions(attrs), do: client().list_transactions(attrs)
  def get_transaction_invoice(id), do: client().get_transaction_invoice(id)

  def construct_webhook_event(payload, sig, secret),
    do: client().construct_webhook_event(payload, sig, secret)
end
