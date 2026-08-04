defmodule EmisarWeb.PostmarkWebhookController do
  @moduledoc """
  Postmark bounce / spam-complaint webhook ingest. Postmark doesn't sign
  its webhooks, so the endpoint is guarded by HTTP Basic Auth — set the same
  secret as the webhook password in Postmark and as `POSTMARK_WEBHOOK_SECRET`
  here; the password is constant-time compared.

  This is the provider boundary and nothing more: it verifies the caller and
  maps Postmark's payload onto `Emisar.Mail`'s provider-neutral deliverability
  command, which owns what a report does to the suppression list. An event type
  we don't act on, or a recognized one whose fields don't map, is acknowledged
  and dropped — Postmark retries any non-2xx and has nothing here to fix.
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
          # No log line here: the route is unauthenticated and publicly POSTable,
          # so a per-request rejection log is free log amplification. Request
          # telemetry already records the 401.
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

  defp handle_event(conn, params) do
    case deliverability_event(params) do
      {:ok, event} -> ack(conn, event.kind, Mail.handle_deliverability_event(event))
      {:ignore, :unsupported} -> json(conn, %{received: true})
      {:error, :invalid_deliverability_event} -> json(conn, %{received: true})
    end
  end

  # Postmark's payload mapped onto the domain command. A delivery/open/click or
  # any other type we don't act on is unsupported; a bounce or complaint whose
  # fields don't validate carries the command's own error.
  defp deliverability_event(%{"RecordType" => "Bounce"} = params) do
    Mail.build_deliverability_event(:bounce, %{
      email: params["Email"],
      inactive: params["Inactive"],
      type: params["Type"],
      description: params["Description"]
    })
  end

  defp deliverability_event(%{"RecordType" => "SpamComplaint"} = params) do
    Mail.build_deliverability_event(:spam_complaint, %{
      email: params["Email"],
      type: params["Type"],
      description: params["Description"]
    })
  end

  defp deliverability_event(_params), do: {:ignore, :unsupported}

  defp ack(conn, _kind, {:ok, :suppressed}), do: json(conn, %{received: true, suppressed: true})
  defp ack(conn, _kind, {:ok, :ignored}), do: json(conn, %{received: true})

  defp ack(conn, kind, {:error, _changeset}) do
    # `kind` is one of the command's finite atoms; the address (PII), the
    # command, and the changeset stay out of the drain.
    Logger.error("postmark webhook suppress failed kind=#{kind}")
    conn |> put_status(:internal_server_error) |> json(%{error: "suppress_failed"})
  end
end
