defmodule EmisarWeb.PaddleWebhookController do
  @moduledoc """
  Paddle webhook ingest. Verifies the HMAC-SHA256 signature
  (`paddle-signature: ts=<unix>;h1=<hex>` over `<ts>:<raw_body>`),
  then hands the event off to `Emisar.Billing.apply_webhook_event/1`.
  Returns 200 on duplicate (already-processed) and no-op events —
  Paddle retries any non-2xx.
  """
  use EmisarWeb, :controller

  require Logger

  alias Emisar.Billing
  alias Emisar.Billing.PaddleClient

  def create(conn, _params) do
    # nil on the EMISAR_DISABLE_BILLING deployment, where the secret is
    # never configured — short-circuit to 503 rather than raising a 500.
    case Application.get_env(:emisar, :paddle_webhook_secret) do
      nil ->
        conn |> put_status(:service_unavailable) |> json(%{error: "billing_disabled"})

      secret ->
        verify_and_handle(conn, secret)
    end
  end

  defp verify_and_handle(conn, secret) do
    with {:ok, body} <- raw_body(conn),
         [signature] <- get_req_header(conn, "paddle-signature"),
         {:ok, event} <- PaddleClient.construct_webhook_event(body, signature, secret) do
      handle_event(conn, event)
    else
      [] ->
        conn |> put_status(:bad_request) |> json(%{error: "missing_signature"})

      {:error, :timestamp_too_old} ->
        Logger.warning("paddle webhook rejected: timestamp outside tolerance window")
        conn |> put_status(:bad_request) |> json(%{error: "timestamp_too_old"})

      {:error, reason} ->
        Logger.warning("paddle webhook rejected: #{inspect(reason)}")
        conn |> put_status(:bad_request) |> json(%{error: "invalid"})
    end
  end

  defp handle_event(conn, %{"event_id" => event_id, "event_type" => type} = event) do
    case Billing.record_and_apply_event(event_id, type, event) do
      :ok ->
        json(conn, %{received: true})

      {:duplicate, _existing} ->
        # Paddle retries the same event on any non-2xx — replying 200
        # on the dup avoids double-applying the same subscription change.
        json(conn, %{received: true, duplicate: true})

      {:error, reason} ->
        Logger.error("paddle webhook apply failed: #{inspect(reason)}")
        conn |> put_status(:internal_server_error) |> json(%{error: "apply_failed"})
    end
  end

  defp handle_event(conn, _malformed) do
    conn |> put_status(:bad_request) |> json(%{error: "malformed_event"})
  end

  # CachedBodyReader stashes the bytes during Plug.Parsers. For tests
  # that hit this controller directly without going through the parser
  # pipeline, fall back to read_body/1.
  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) ->
        {:ok, body}

      _ ->
        case read_body(conn, length: 1_048_576) do
          {:ok, body, _conn} -> {:ok, body}
          {:more, _, _} -> {:error, :payload_too_large}
          err -> err
        end
    end
  end
end
