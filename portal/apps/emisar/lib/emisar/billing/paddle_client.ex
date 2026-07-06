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
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback create_billing_portal_session(map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_products() :: {:ok, [map()]} | {:error, term()}
  @callback list_transactions(map()) :: {:ok, [map()]} | {:error, term()}
  @callback get_transaction_invoice(String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback construct_webhook_event(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}

  defp client, do: Application.fetch_env!(:emisar, :paddle_client)

  def create_customer(attrs), do: client().create_customer(attrs)
  def create_checkout_session(attrs), do: client().create_checkout_session(attrs)
  def create_billing_portal_session(attrs), do: client().create_billing_portal_session(attrs)
  def retrieve_subscription(id), do: client().retrieve_subscription(id)
  def list_products, do: client().list_products()
  def list_transactions(attrs), do: client().list_transactions(attrs)
  def get_transaction_invoice(id), do: client().get_transaction_invoice(id)

  def construct_webhook_event(payload, sig, secret),
    do: client().construct_webhook_event(payload, sig, secret)
end
