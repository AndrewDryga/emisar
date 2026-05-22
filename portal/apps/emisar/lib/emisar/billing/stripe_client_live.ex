defmodule Emisar.Billing.StripeClient.Live do
  @moduledoc """
  Production Stripe wrapper. Uses Finch via `Emisar.Finch` for HTTPS;
  signs requests with the configured `:stripe_secret_key`.

  Kept small on purpose: we touch exactly the four endpoints used by
  the rest of the app. Webhook signature verification uses the
  HMAC-SHA256 scheme from Stripe's docs.
  """

  @behaviour Emisar.Billing.StripeClient

  @base "https://api.stripe.com/v1"

  @impl true
  def create_customer(%{email: email} = attrs) do
    post("/customers", %{
      "email" => email,
      "name" => attrs[:name],
      "metadata[account_id]" => attrs[:account_id]
    })
  end

  @impl true
  def create_checkout_session(attrs) do
    post("/checkout/sessions", %{
      "customer" => attrs[:customer],
      "mode" => "subscription",
      "line_items[0][price]" => attrs[:price_id],
      "line_items[0][quantity]" => attrs[:quantity] || 1,
      "success_url" => attrs[:success_url],
      "cancel_url" => attrs[:cancel_url],
      "allow_promotion_codes" => "true"
    })
  end

  @impl true
  def create_billing_portal_session(attrs) do
    post("/billing_portal/sessions", %{
      "customer" => attrs[:customer],
      "return_url" => attrs[:return_url]
    })
  end

  @impl true
  def retrieve_subscription(id), do: get("/subscriptions/#{id}")

  @impl true
  def construct_webhook_event(payload, signature, secret) do
    case verify_signature(payload, signature, secret) do
      :ok ->
        case Jason.decode(payload) do
          {:ok, event} -> {:ok, event}
          err -> err
        end

      err ->
        err
    end
  end

  # Stripe's recommended tolerance window. Webhooks delivered outside
  # this window are rejected to prevent replay of captured payloads.
  @tolerance_seconds 300

  defp verify_signature(payload, signature_header, secret) do
    parts =
      signature_header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.into(%{}, fn [k, v] -> {k, v} end)

    with {:ok, timestamp_str} <- Map.fetch(parts, "t"),
         {:ok, expected} <- Map.fetch(parts, "v1"),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         :ok <- check_timestamp(timestamp),
         signed_payload <- "#{timestamp}.#{payload}",
         computed <- :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower),
         true <- secure_compare(computed, expected) do
      :ok
    else
      {:error, _} = err -> err
      _ -> {:error, :signature_mismatch}
    end
  end

  defp check_timestamp(ts) do
    delta = abs(System.system_time(:second) - ts)

    if delta > @tolerance_seconds do
      {:error, :timestamp_too_old}
    else
      :ok
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_compare(_, _), do: false

  defp post(path, params) do
    req = Finch.build(:post, @base <> path, headers(), URI.encode_query(params))

    case Finch.request(req, Emisar.Finch) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp get(path) do
    req = Finch.build(:get, @base <> path, headers())

    case Finch.request(req, Emisar.Finch) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, _} = err ->
        err
    end
  end

  defp headers do
    secret = Application.fetch_env!(:emisar, :stripe_secret_key)
    [
      {"authorization", "Bearer " <> secret},
      {"content-type", "application/x-www-form-urlencoded"}
    ]
  end
end
