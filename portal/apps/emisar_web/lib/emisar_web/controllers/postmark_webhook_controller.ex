defmodule EmisarWeb.PostmarkWebhookController do
  @moduledoc """
  Postmark bounce / spam-complaint webhook ingest. Postmark doesn't sign
  its webhooks, so the endpoint is guarded by HTTP Basic Auth — set the same
  secret as the webhook password in Postmark and as `POSTMARK_WEBHOOK_SECRET`
  here; the password is constant-time compared.

  A permanent bounce (Postmark flips `Inactive` to true once it stops
  delivering to the address) or a spam complaint adds the address to
  `Emisar.Mail`'s suppression list, so the transactional mailer stops sending
  to it. Transient bounces and every other event type are acknowledged and
  ignored. Always replies 200 on a verified request — Postmark retries any
  non-2xx, which would re-suppress the same address harmlessly anyway.
  """
  use EmisarWeb, :controller
  alias Emisar.{Crypto, Mail}
  require Logger

  def create(conn, params) do
    case Emisar.Config.get_env(:emisar, :postmark_webhook_secret) do
      nil ->
        conn |> put_status(:service_unavailable) |> json(%{error: "webhook_disabled"})

      secret ->
        if authorized?(conn, secret) do
          handle_event(conn, params)
        else
          Logger.warning("postmark webhook rejected: bad credentials")
          conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
        end
    end
  end

  # Postmark sends the configured Basic Auth credentials; only the password
  # has to match the shared secret (the username is ignored).
  defp authorized?(conn, secret) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [_user, password] <- String.split(decoded, ":", parts: 2) do
      Crypto.secure_compare(password, secret)
    else
      _ -> false
    end
  end

  # A permanent bounce — Postmark sets `Inactive: true` once it deactivates
  # the address — suppresses it.
  defp handle_event(conn, %{"RecordType" => "Bounce", "Email" => email, "Inactive" => true} = p)
       when is_binary(email) do
    suppress_and_ack(conn, email, :hard_bounce, bounce_detail(p))
  end

  defp handle_event(conn, %{"RecordType" => "SpamComplaint", "Email" => email} = p)
       when is_binary(email) do
    suppress_and_ack(conn, email, :spam_complaint, bounce_detail(p))
  end

  # A transient bounce (`Inactive: false`), a delivery/open/click event, or a
  # malformed payload: ack so Postmark stops retrying, change nothing.
  defp handle_event(conn, _params), do: json(conn, %{received: true})

  defp suppress_and_ack(conn, email, reason, detail) do
    case Mail.suppress(email, reason, detail) do
      {:ok, _suppression} ->
        json(conn, %{received: true, suppressed: true})

      {:error, _changeset} ->
        # Don't echo the address or changeset into the drain — the email is PII.
        Logger.error("postmark webhook suppress failed reason=#{reason}")
        conn |> put_status(:internal_server_error) |> json(%{error: "suppress_failed"})
    end
  end

  defp bounce_detail(%{"Type" => type, "Description" => desc})
       when is_binary(type) and is_binary(desc),
       do: "#{type}: #{desc}"

  defp bounce_detail(%{"Type" => type}) when is_binary(type), do: type
  defp bounce_detail(_), do: nil
end
