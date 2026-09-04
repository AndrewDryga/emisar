defmodule EmisarWeb.AuditDownloadController do
  @moduledoc """
  CSV download of the audit trail — the CURRENT FILTERED VIEW, straight from
  the browser session (unlike `AuditExportController`, the api-key NDJSON feed
  for SIEM collectors). Accepts the same query params as the audit LiveView,
  so the Export button hands over whatever the operator is looking at.

  Plan-gated: audit export (this download and the SIEM API alike) is a Team+
  feature — the in-console trail stays on every plan; taking the data OUT is
  the paid surface.

  The adapter half only: param translation, flashes, and the chunked response.
  The row cap, the CSV encoding, and the export receipt live in
  `Emisar.Audit.CSVExport`, reached through `Audit.stream_csv_export/2`.
  """
  use EmisarWeb, :controller
  alias Emisar.{Audit, Billing}
  alias EmisarWeb.LiveTable
  require Logger

  # require_sso / require_mfa are enforced on LiveViews by `on_mount` hooks that
  # do NOT run for this controller route (nested in the slug `live_session`). The
  # plug re-checks the resolved account BEFORE any audit data is read, so a
  # magic-link session in an enforcing account is bounced to the step-up instead
  # of streaming the trail.
  plug EmisarWeb.Plugs.EnsureAccountCompliance

  @filter_params ~w[
    category from to event_type outcome request_id auth_method
    actor_kind actor_id target_kind target_id
  ]

  def download(conn, params) do
    subject = conn.assigns.current_subject
    account = conn.assigns.current_account

    cond do
      not Audit.subject_can_view_audit?(subject) ->
        conn
        |> put_flash(:error, "You don't have permission to export the audit log.")
        |> redirect(to: ~p"/app/#{account}")

      # Courtesy navigation — `Audit.list_events_for_export/2` enforces the
      # same gate authoritatively; this branch just lands on the upgrade page.
      not Billing.audit_export_available?(account) ->
        conn
        |> put_flash(:info, "Audit export is available on the Team plan.")
        |> redirect(to: ~p"/app/#{account}/settings/billing")

      true ->
        start_download(conn, subject, account, params)
    end
  end

  defp start_download(conn, subject, account, params) do
    filter_params = audit_filter_params(params)
    opts = list_opts(filter_params, subject)

    case Audit.stream_csv_export(subject, opts) do
      {:ok, csv} ->
        filename =
          "audit-#{account.slug}-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")}.csv"

        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_chunked(200)
        |> stream_chunks(csv)

      {:error, reason} ->
        log_csv_preparation_failure(reason)

        conn
        |> put_flash(:error, csv_preparation_error(reason))
        |> redirect(to: ~p"/app/#{account}/audit?#{filter_params}")
    end
  end

  defp csv_preparation_error({:too_many_rows, %{count: count, max: max}}) do
    "This view has #{count} events — the CSV download caps at #{max}. " <>
      "Narrow the filters, or contact Support and we'll prepare the complete export."
  end

  defp csv_preparation_error(:nothing_to_export),
    do: "Nothing to export — this view has no events."

  defp csv_preparation_error(_reason),
    do: "The CSV could not be prepared. Nothing was downloaded; try again."

  defp log_csv_preparation_failure(:nothing_to_export), do: :ok
  defp log_csv_preparation_failure({:too_many_rows, _facts}), do: :ok

  defp log_csv_preparation_failure(reason) do
    Logger.error("audit CSV preparation did not complete: #{inspect(reason)}")
  end

  # A client that goes away mid-download ends the walk; the stream's receipt
  # still records the rows that left.
  defp stream_chunks(conn, csv) do
    Enum.reduce_while(csv, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  # The SAME filter surface the audit LiveView applies: the applicable base
  # filters (conditional facets included) plus the actor/target pivots that
  # ride outside the form.
  defp list_opts(params, subject) do
    base_filters = Audit.applicable_event_filters(params["event_type"], params, subject)

    params
    |> LiveTable.params_to_opts(base_filters)
    |> Keyword.merge(
      actor_id: blank_to_nil(params["actor_id"]),
      target_id: blank_to_nil(params["target_id"])
    )
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp audit_filter_params(params), do: Map.take(params, @filter_params)
end
