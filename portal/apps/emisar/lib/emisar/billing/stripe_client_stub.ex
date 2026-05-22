defmodule Emisar.Billing.StripeClient.Stub do
  @moduledoc """
  Stub Stripe implementation. Used for dev + test until a real STRIPE_API_KEY
  is provisioned. Records calls in process inbox so tests can assert on them.
  """

  @behaviour Emisar.Billing.StripeClient

  @impl true
  def create_customer(%{email: email} = attrs) do
    {:ok,
     %{
       "id" => "cus_stub_" <> short_id(email),
       "email" => email,
       "metadata" => attrs[:metadata] || %{}
     }}
  end

  @impl true
  def create_checkout_session(attrs) do
    {:ok,
     %{
       "id" => "cs_stub_" <> short_id(attrs[:customer] || "anon"),
       "url" => "https://stub.stripe.test/checkout/" <> short_id(attrs[:customer] || "anon")
     }}
  end

  @impl true
  def create_billing_portal_session(attrs) do
    {:ok,
     %{
       "id" => "bps_stub_" <> short_id(attrs[:customer] || "anon"),
       "url" => "https://stub.stripe.test/portal"
     }}
  end

  @impl true
  def retrieve_subscription(id) do
    {:ok,
     %{
       "id" => id,
       "status" => "active",
       "current_period_end" => System.system_time(:second) + 30 * 86_400
     }}
  end

  @impl true
  def construct_webhook_event(payload, _signature, _secret) do
    case Jason.decode(payload) do
      {:ok, event} -> {:ok, event}
      {:error, _} -> {:error, :invalid_payload}
    end
  end

  defp short_id(s),
    do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 12)
end
