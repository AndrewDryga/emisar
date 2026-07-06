defmodule Emisar.Billing.PaddleClient.Live do
  @moduledoc """
  Production Paddle wrapper. Uses Finch via `Emisar.Finch` for HTTPS;
  signs requests with the configured `:paddle_api_key`.

  Kept small on purpose: we touch exactly the endpoints used by
  the rest of the app. Webhook signature verification uses Paddle's
  HMAC-SHA256 scheme — header `paddle-signature: ts=<unix>;h1=<hex>`,
  signed over `<ts>:<raw_body>`.
  """

  @behaviour Emisar.Billing.PaddleClient

  @live_base "https://api.paddle.com"
  @sandbox_base "https://sandbox-api.paddle.com"

  @impl true
  def create_customer(attrs) do
    body = %{
      "email" => attrs[:email],
      "name" => attrs[:name],
      "custom_data" => %{"account_id" => attrs[:account_id]}
    }

    with {:ok, %{"data" => %{"id" => id} = data}} <- post_json("/customers", body) do
      {:ok, Map.put(data, "id", id)}
    end
  end

  @impl true
  def create_checkout_session(attrs) do
    # No checkout.url on the transaction: Paddle then mints data.checkout.url
    # from the account's default payment link (our /checkout page) + ?_ptxn= —
    # an explicit override would need its own domain approval for zero gain.
    body = %{
      "customer_id" => attrs[:customer],
      "items" => [%{"price_id" => attrs[:price_id], "quantity" => attrs[:quantity] || 1}]
    }

    with {:ok, %{"data" => %{"checkout" => %{"url" => url}} = data}} <-
           post_json("/transactions", body) do
      {:ok, Map.put(data, "url", url)}
    end
  end

  @impl true
  def create_billing_portal_session(attrs) do
    with {:ok,
          %{
            "data" =>
              %{
                "urls" => %{"general" => %{"overview" => url}}
              } = data
          }} <-
           post_json("/customers/#{attrs[:customer]}/portal-sessions", %{}) do
      {:ok, Map.put(data, "url", url)}
    end
  end

  @impl true
  def retrieve_subscription(id) do
    case get("/subscriptions/#{id}") do
      {:ok, %{"data" => sub}} -> {:ok, sub}
      other -> other
    end
  end

  @impl true
  def list_products do
    # The catalog is a handful of products; per_page=200 is far above any
    # real count, so pagination is deliberately not followed.
    case get("/products?include=prices&status=active&per_page=200") do
      {:ok, %{"data" => products}} -> {:ok, products}
      other -> other
    end
  end

  @impl true
  def list_transactions(%{customer: customer_id} = attrs) do
    limit = attrs[:limit] || 10

    # Only the statuses that represent an actual invoice (a draft/canceled txn
    # isn't one); newest first, a single page — this is "recent invoices", not
    # a full ledger. The portal link owns the complete history + PDFs.
    query =
      "customer_id=#{customer_id}&status=billed,completed,past_due" <>
        "&order_by=billed_at[DESC]&per_page=#{limit}"

    case get("/transactions?#{query}") do
      {:ok, %{"data" => txns}} -> {:ok, txns}
      other -> other
    end
  end

  @impl true
  def construct_webhook_event(payload, signature, secret) do
    with :ok <- verify_signature(payload, signature, secret),
         {:ok, event} <- Jason.decode(payload) do
      {:ok, event}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Paddle's recommended tolerance window. Webhooks delivered outside
  # this window are rejected to prevent replay of captured payloads.
  @tolerance_seconds 300

  defp verify_signature(payload, signature_header, secret) do
    parts =
      signature_header
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.into(%{}, fn
        [k, v] -> {k, v}
        _ -> {nil, nil}
      end)

    with {:ok, timestamp_str} <- Map.fetch(parts, "ts"),
         {:ok, expected} <- Map.fetch(parts, "h1"),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         :ok <- check_timestamp(timestamp),
         signed_payload = "#{timestamp}:#{payload}",
         computed = compute_signature(secret, signed_payload),
         true <- Emisar.Crypto.secure_compare(computed, expected) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :signature_mismatch}
    end
  end

  defp compute_signature(secret, signed_payload),
    do: :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

  defp check_timestamp(timestamp) do
    delta = abs(System.system_time(:second) - timestamp)

    if delta > @tolerance_seconds do
      {:error, :timestamp_too_old}
    else
      :ok
    end
  end

  defp post_json(path, params) do
    body = Jason.encode!(params)
    request = Finch.build(:post, base() <> path, headers(), body)

    case Finch.request(request, Emisar.Finch, receive_timeout: 8_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get(path) do
    request = Finch.build(:get, base() <> path, headers())

    case Finch.request(request, Emisar.Finch, receive_timeout: 8_000) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Sandbox keys carry the _sdbx_ marker, so ONE secret switches the whole
  # environment — no separate env var to drift out of sync with the key.
  defp base do
    if String.contains?(api_key(), "_sdbx_"), do: @sandbox_base, else: @live_base
  end

  defp headers do
    [
      {"authorization", "Bearer " <> api_key()},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  defp api_key, do: Application.fetch_env!(:emisar, :paddle_api_key)
end
