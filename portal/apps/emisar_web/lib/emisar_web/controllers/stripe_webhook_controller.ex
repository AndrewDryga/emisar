defmodule EmisarWeb.StripeWebhookController do
  @moduledoc """
  Stripe webhook ingest. Verifies the signature, then hands the event
  off to `Emisar.Billing.apply_webhook_event/1`. Returns 200 on
  duplicate (already-processed) and no-op events — Stripe retries any
  non-2xx.
  """
  use EmisarWeb, :controller

  require Logger

  alias Emisar.Billing
  alias Emisar.Billing.StripeClient

  def create(conn, _params) do
    secret = Application.fetch_env!(:emisar, :stripe_webhook_secret)

    with {:ok, body} <- raw_body(conn),
         [signature] <- get_req_header(conn, "stripe-signature"),
         {:ok, event} <- StripeClient.construct_webhook_event(body, signature, secret) do
      handle_event(conn, event)
    else
      [] ->
        conn |> put_status(:bad_request) |> json(%{error: "missing_signature"})

      {:error, :timestamp_too_old} ->
        Logger.warning("stripe webhook rejected: timestamp outside tolerance window")
        conn |> put_status(:bad_request) |> json(%{error: "timestamp_too_old"})

      {:error, reason} ->
        Logger.warning("stripe webhook rejected: #{inspect(reason)}")
        conn |> put_status(:bad_request) |> json(%{error: "invalid"})
    end
  end

  defp handle_event(conn, %{"id" => event_id, "type" => type} = event) do
    case Billing.record_and_apply_event(event_id, type, event) do
      :ok ->
        json(conn, %{received: true})

      {:duplicate, _existing} ->
        # Stripe retries the same event on any non-2xx — replying 200
        # on the dup avoids double-applying the same subscription change.
        json(conn, %{received: true, duplicate: true})

      {:error, reason} ->
        Logger.error("stripe webhook apply failed: #{inspect(reason)}")
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
