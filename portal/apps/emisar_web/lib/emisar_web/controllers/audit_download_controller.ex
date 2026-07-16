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

  # require_sso / require_mfa are enforced on LiveViews by `on_mount` hooks that
  # do NOT run for this controller route (nested in the slug `live_session`). The
  # plug re-checks the resolved account BEFORE any audit data is read, so a
  # magic-link session in an enforcing account is bounced to the step-up instead
  # of streaming the trail.
  plug EmisarWeb.Plugs.EnsureAccountCompliance

  # 100 is the paginator's hard page cap. The row bound is checked UP FRONT
  # with one count and over-bound downloads are REFUSED (never silently
  # truncated — a forensic export that looks complete but isn't would be worse
  # than an error); the page guard is just the belt to that check's suspenders.
  @page_limit 100

  defp max_rows, do: Application.get_env(:emisar_web, :audit_download_max_rows, 100_000)
  defp max_pages, do: div(max_rows() + @page_limit - 1, @page_limit)

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
        |> put_flash(:info, "Audit export is available on the Team plan.")
        |> redirect(to: ~p"/app/#{account}/settings/billing")

      true ->
        start_download(conn, subject, account, params)
    end
  end

  # ONE up-front count decides honestly: within bounds → stream it all;
  # over → refuse with the right tool named (the SIEM API is cursor-resumable
  # NDJSON, built for full-history extracts), never a truncated file.
  defp start_download(conn, subject, account, params) do
    opts = list_opts(params, subject)

    case Audit.list_events(subject, Keyword.put(opts, :page, limit: 1)) do
      {:ok, _probe, %{count: count}} when count > 0 ->
        if count <= max_rows() do
          stream_csv(conn, subject, account, opts, params)
        else
          conn
          |> put_flash(
            :error,
            "This view has #{count} events — the CSV download caps at #{max_rows()}. " <>
              "Narrow the filters, or pull the full trail through the SIEM export API."
          )
          |> redirect(to: ~p"/app/#{account}/audit?#{Map.drop(params, ["account_id_or_slug"])}")
        end

      _ ->
        conn
        |> put_flash(:error, "Nothing to export — this view has no events.")
        |> redirect(to: ~p"/app/#{account}/audit?#{Map.drop(params, ["account_id_or_slug"])}")
    end
  end

  defp stream_csv(conn, subject, account, opts, _params) do
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
      Audit.Event.Query.applicable_filters(
        Audit.Event.Query.filters(),
        params["event_type"],
        params
      )

    params
    |> LiveTable.params_to_opts(base_filters)
    |> Keyword.merge(
      actor_id: blank_to_nil(params["actor_id"]),
      target_id: blank_to_nil(params["target_id"])
    )
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp stream_pages(conn, subject, opts, cursor, pages, count) do
    if pages >= max_pages() do
      {conn, count}
    else
      stream_page(conn, subject, opts, cursor, pages, count)
    end
  end

  defp stream_page(conn, subject, opts, cursor, pages, count) do
    # count: false — a walk must not re-count the whole filtered set per page
    # (the up-front probe already counted once).
    page_opts = opts |> Keyword.put(:page, page(cursor)) |> Keyword.put(:count, false)

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
  # commas, newlines, and the payload JSON, with no csv dependency. A tab
  # prefix keeps a spreadsheet from evaluating attacker-controlled audit data
  # as a formula when an operator opens the export.
  defp csv_field(nil), do: ~s("")

  defp csv_field(value) do
    value
    |> to_string()
    |> formula_safe()
    |> String.replace(~s("), ~s(""))
    |> then(&(~s(") <> &1 <> ~s(")))
  end

  defp formula_safe(value) do
    if String.starts_with?(String.trim_leading(value), ["=", "+", "-", "@"]) do
      "\t" <> value
    else
      value
    end
  end
end
