defmodule Emisar.Billing.PaddleClient.Stub do
  @moduledoc """
  Stub Paddle implementation. Used for dev + test until real PADDLE_API_KEY
  credentials are provisioned. Returns predictable stubs so tests pass
  without a real API.
  """

  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def create_customer(%{email: email} = attrs) do
    {:ok,
     %{
       "id" => "ctm_stub_" <> short_id(email || "anon"),
       "email" => email,
       "custom_data" => %{"account_id" => attrs[:account_id]}
     }}
  end

  def create_customer(attrs) do
    {:ok,
     %{
       "id" => "ctm_stub_" <> short_id(attrs[:name] || "anon"),
       "custom_data" => %{"account_id" => attrs[:account_id]}
     }}
  end

  @impl true
  def create_checkout_session(attrs) do
    {:ok,
     %{
       "id" => "txn_stub_" <> short_id(attrs[:customer] || "anon"),
       "url" => "https://stub.paddle.test/checkout/" <> short_id(attrs[:customer] || "anon")
     }}
  end

  @impl true
  def create_billing_portal_session(attrs) do
    {:ok,
     %{
       "id" => "pst_stub_" <> short_id(attrs[:customer] || "anon"),
       "url" => "https://stub.paddle.test/portal"
     }}
  end

  @impl true
  def retrieve_subscription(id) do
    {:ok,
     %{
       "id" => id,
       "status" => "active",
       "next_billed_at" =>
         DateTime.utc_now()
         |> DateTime.add(30 * 86_400, :second)
         |> DateTime.to_iso8601()
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
