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
         {:ok, event} <- Billing.PaddleClient.construct_webhook_event(body, signature, secret) do
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
        # Log the event id + a short reason summary, never `inspect(reason)`:
        # an apply failure carries an Ecto changeset whose error term can echo
        # Paddle payload fragments (customer ids, amounts) into the log drain.
        Logger.error(
          "paddle webhook apply failed event_id=#{event_id} reason=#{reason_summary(reason)}"
        )

        conn |> put_status(:internal_server_error) |> json(%{error: "apply_failed"})
    end
  end

  defp handle_event(conn, _malformed) do
    conn |> put_status(:bad_request) |> json(%{error: "malformed_event"})
  end

  # A loggable summary that never carries payload values. For a changeset
  # we surface only which fields failed (names, not values); everything
  # else collapses to its atom tag or a generic label.
  defp reason_summary({:apply_failed, reason}), do: reason_summary(reason)

  defp reason_summary(%Ecto.Changeset{errors: errors}) do
    fields = errors |> Keyword.keys() |> Enum.uniq() |> Enum.join(",")
    "invalid_changeset[#{fields}]"
  end

  defp reason_summary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_summary(_), do: "unknown"

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
