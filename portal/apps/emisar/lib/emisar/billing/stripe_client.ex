defmodule Emisar.Billing.StripeClient do
  @moduledoc """
  Behaviour wrapping the Stripe API surface we use. Concrete
  implementation lives in `StripeClient.Live`; tests use
  `StripeClient.Stub`.

  We intentionally call out only the four operations we need —
  customer creation, checkout-session creation, subscription read,
  webhook signature verify. Everything else can be added when a
  legitimate need surfaces.
  """

  @callback create_customer(map()) :: {:ok, map()} | {:error, term()}
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback create_billing_portal_session(map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  @callback construct_webhook_event(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}

  defp client, do: Application.fetch_env!(:emisar, :stripe_client)

  def create_customer(attrs), do: client().create_customer(attrs)
  def create_checkout_session(attrs), do: client().create_checkout_session(attrs)
  def create_billing_portal_session(attrs), do: client().create_billing_portal_session(attrs)
  def retrieve_subscription(id), do: client().retrieve_subscription(id)
  def construct_webhook_event(payload, sig, secret),
    do: client().construct_webhook_event(payload, sig, secret)
end
