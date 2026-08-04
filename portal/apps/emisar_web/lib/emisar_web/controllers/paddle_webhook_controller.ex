defmodule EmisarWeb.PaddleWebhookController do
  @moduledoc """
  Paddle webhook ingest. Reads the raw request body plus its single
  `paddle-signature` header and hands both to
  `Emisar.Billing.ingest_paddle_webhook/2`, which owns signature
  verification and the dedup/apply sequencing; this controller only maps
  its outcome onto HTTP. Returns 200 on duplicate (already-processed) and
  no-op events — Paddle retries any non-2xx.
  """
  use EmisarWeb, :controller
  alias Emisar.Billing
  require Logger

  def create(conn, _params) do
    with {:ok, body} <- raw_body(conn),
         [signature] <- get_req_header(conn, "paddle-signature") do
      respond(conn, Billing.ingest_paddle_webhook(body, signature))
    else
      [] ->
        conn |> put_status(:bad_request) |> json(%{error: "missing_signature"})

      # Duplicate signature headers, or a body we couldn't read — neither
      # reaches billing, and neither is loggable without echoing the request.
      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid"})
    end
  end

  defp respond(conn, :ok), do: json(conn, %{received: true})

  defp respond(conn, {:duplicate, _event_id}) do
    # Paddle retries the same event on any non-2xx — replying 200
    # on the dup avoids double-applying the same subscription change.
    json(conn, %{received: true, duplicate: true})
  end

  defp respond(conn, {:error, :billing_disabled}) do
    # No secret on the EMISAR_DISABLE_BILLING deployment — say so with a
    # retryable 503 rather than raising a 500.
    conn |> put_status(:service_unavailable) |> json(%{error: "billing_disabled"})
  end

  defp respond(conn, {:error, {:verification_failed, :timestamp_too_old}}) do
    Logger.warning("paddle webhook rejected: timestamp outside tolerance window")
    conn |> put_status(:bad_request) |> json(%{error: "timestamp_too_old"})
  end

  defp respond(conn, {:error, {:verification_failed, reason}}) do
    # Not every verification reason is one of the client's own atoms: a body
    # that passes the signature gate and then fails to decode arrives as a
    # `Jason.DecodeError` carrying the raw request bytes, so summarize rather
    # than inspect.
    Logger.warning("paddle webhook rejected: #{reason_summary(reason)}")
    conn |> put_status(:bad_request) |> json(%{error: "invalid"})
  end

  defp respond(conn, {:error, :malformed_event}) do
    conn |> put_status(:bad_request) |> json(%{error: "malformed_event"})
  end

  defp respond(conn, {:error, reason}) do
    # Log a short reason summary, never `inspect(reason)`: an apply failure
    # carries an Ecto changeset whose error term can echo Paddle payload
    # fragments (customer ids, amounts) into the log drain.
    Logger.error("paddle webhook apply failed reason=#{reason_summary(reason)}")

    conn |> put_status(:internal_server_error) |> json(%{error: "apply_failed"})
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
