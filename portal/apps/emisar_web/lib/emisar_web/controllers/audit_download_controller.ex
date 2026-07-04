defmodule EmisarWeb.AuditDownloadController do
  @moduledoc """
  CSV download of the audit trail — the CURRENT FILTERED VIEW, straight from
  the browser session (unlike `AuditExportController`, the api-key NDJSON feed
  for SIEM collectors). Accepts the same query params as the audit LiveView,
  so the Export button hands over whatever the operator is looking at.

  Plan-gated: audit export (this download and the SIEM API alike) is a Team+
  feature — the in-console trail stays on every plan; taking the data OUT is
  the paid surface.
  """
  use EmisarWeb, :controller
  alias Emisar.{Audit, Billing}
  alias EmisarWeb.{LiveTable, TimeHelpers}

  # 100 is the paginator's hard page cap; 500 pages bounds a runaway download
  # at 50k rows — beyond that, the SIEM API is the right tool.
  @page_limit 100
  @max_pages 500

  def download(conn, params) do
    subject = conn.assigns.current_subject
    account = conn.assigns.current_account

    cond do
      not Audit.subject_can_view_audit?(subject) ->
        conn
        |> put_flash(:error, "You don't have permission to export the audit log.")
        |> redirect(to: ~p"/app/#{account}")

      not Billing.audit_export_available?(account) ->
        conn
        |> put_flash(:error, "Audit export is available on the Team plan.")
        |> redirect(to: ~p"/app/#{account}/settings/billing")

      true ->
        stream_csv(conn, subject, account, params)
    end
  end

  defp stream_csv(conn, subject, account, params) do
    opts = list_opts(params, subject)

    filename =
      "audit-#{account.slug}-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")}.csv"

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, csv_header())
    {conn, count} = stream_pages(conn, subject, opts, nil, 0, 0)

    # Self-log the export exactly like the SIEM API does — "watch the
    # watchers". Skipped for an empty result, matching record_export/3.
    Audit.record_export(subject, opts, count)
    conn
  end

  # The SAME filter surface the audit LiveView applies: the applicable base
  # filters (conditional facets included) plus the actor/target pivots that
  # ride outside the form.
  defp list_opts(params, _subject) do
    base_filters =
      Audit.Event.Query.applicable_filters(Audit.Event.Query.filters(), params["event_type"])

    params
    |> LiveTable.params_to_opts(base_filters)
    |> Keyword.merge(
      actor_id: blank_to_nil(params["actor_id"]),
      target_id: blank_to_nil(params["target_id"])
    )
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp stream_pages(conn, subject, opts, cursor, pages, count) when pages < @max_pages do
    page_opts = Keyword.put(opts, :page, page(cursor))

    case Audit.list_events(subject, page_opts) do
      {:ok, [], _meta} ->
        {conn, count}

      {:ok, events, meta} ->
        {:ok, conn} = chunk(conn, Enum.map(events, &csv_row/1))

        case meta.next_page_cursor do
          nil -> {conn, count + length(events)}
          next -> stream_pages(conn, subject, opts, next, pages + 1, count + length(events))
        end

      {:error, _} ->
        {conn, count}
    end
  end

  defp stream_pages(conn, _subject, _opts, _cursor, _pages, count), do: {conn, count}

  defp page(nil), do: [limit: @page_limit]
  defp page(cursor), do: [limit: @page_limit, cursor: cursor]

  defp csv_header do
    "occurred_at_utc,event_type,severity,actor_kind,actor_id,actor_label," <>
      "target_kind,target_id,target_label,ip_address,auth_method,request_id,payload\r\n"
  end

  defp csv_row(event) do
    [
      TimeHelpers.forensic_time(event.occurred_at),
      event.event_type,
      event.event_type |> Emisar.Audit.Event.Query.outcome() |> Atom.to_string(),
      event.actor_kind,
      event.actor_id,
      event.actor_label,
      event.target_kind,
      event.target_id,
      event.target_label,
      event.ip_address,
      event.auth_method,
      event.request_id,
      Jason.encode!(event.payload || %{})
    ]
    |> Enum.map_join(",", &csv_field/1)
    |> Kernel.<>("\r\n")
  end

  # Always-quoted + doubled internal quotes — correct for every value incl.
  # commas, newlines, and the payload JSON, with no csv dependency.
  defp csv_field(nil), do: ~s("")
  defp csv_field(value), do: ~s(") <> String.replace(to_string(value), ~s("), ~s("")) <> ~s(")
end
