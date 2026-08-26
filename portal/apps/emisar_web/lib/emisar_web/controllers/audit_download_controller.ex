defmodule EmisarWeb.AuditDownloadController do
  @moduledoc """
  CSV download of the audit trail — the CURRENT FILTERED VIEW, straight from
  the browser session (unlike `AuditExportController`, the api-key NDJSON feed
  for SIEM collectors). Accepts the same query params as the audit LiveView,
  so the Export button hands over whatever the operator is looking at.

  An account owner may create one downloadable CSV on any plan. The one-time
  allowance is consumed after the bounded file and its audit receipt are
  prepared, before the browser transfer begins. The paid continuous-export
  entitlement allows repeated CSV downloads for every full-trail role; it also
  governs the separate SIEM API.
  """
  use EmisarWeb, :controller
  alias Emisar.Audit
  alias EmisarWeb.AuditDownloadLimiter
  alias EmisarWeb.{LiveTable, TimeHelpers}
  require Logger

  # require_sso / require_mfa are enforced on LiveViews by `on_mount` hooks that
  # do NOT run for this controller route (nested in the slug `live_session`). The
  # plug re-checks the resolved account BEFORE any audit data is read, so a
  # magic-link session in an enforcing account is bounced to the step-up instead
  # of streaming the trail.
  plug EmisarWeb.Plugs.EnsureAccountCompliance

  # Build the bounded file completely BEFORE committing response headers. A
  # later page/read failure must not look like a valid, cleanly terminated CSV,
  # and a replaced one-time lease must lose at the atomic completion fence
  # before either request can send bytes. The byte cap also keeps an adversarial
  # set of maximum-sized audit rows from filling the node's temporary volume.
  @page_limit 100
  @default_max_bytes 256 * 1024 * 1024
  @filter_params ~w[
    category from to event_type outcome request_id auth_method
    actor_kind actor_id target_kind target_id
  ]

  defp max_rows, do: Emisar.Config.get_env(:emisar_web, :audit_download_max_rows, 100_000)

  defp max_bytes,
    do: Emisar.Config.get_env(:emisar_web, :audit_download_max_bytes, @default_max_bytes)

  defp max_pages, do: div(max_rows() + @page_limit - 1, @page_limit)

  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "Method Not Allowed")
  end

  def download(conn, params) do
    subject = conn.assigns.current_subject
    account = conn.assigns.current_account

    case Audit.csv_export_access(subject) do
      :unauthorized ->
        conn
        |> put_flash(:error, "You don't have permission to export the audit log.")
        |> redirect(to: ~p"/app/#{account}")

      :used ->
        csv_already_used(conn, account)

      :unavailable ->
        conn
        |> put_flash(
          :info,
          "Repeated CSV export is available on Team. Ask an account owner for the one-time CSV."
        )
        |> redirect(to: ~p"/app/#{account}/settings/billing")

      access when access in [:repeatable, :one_time] ->
        case AuditDownloadLimiter.run(account.id, fn ->
               start_download(conn, subject, account, params, access)
             end) do
          {:error, :audit_download_saturated} ->
            conn
            |> put_flash(
              :info,
              "Another audit CSV is being prepared. Wait for it to finish and try again."
            )
            |> redirect(to: ~p"/app/#{account}/audit")

          result ->
            result
        end
    end
  end

  # ONE up-front count decides honestly: within bounds → write it all;
  # over → refuse with the right tool named (the SIEM API is cursor-resumable
  # NDJSON, built for full-history extracts), never a truncated file.
  defp start_download(conn, subject, account, params, access) do
    filter_params = audit_filter_params(params)
    opts = list_opts(filter_params, subject)

    probe_opts = opts |> Keyword.put(:page, limit: 1) |> Keyword.put(:count, true)

    case Audit.list_events(subject, probe_opts) do
      {:ok, _probe, %{count: count}} when count > 0 ->
        if count <= max_rows() do
          begin_csv_download(conn, subject, account, opts, filter_params)
        else
          conn
          |> put_flash(
            :error,
            oversized_export_message(count, access)
          )
          |> redirect(to: ~p"/app/#{account}/audit?#{filter_params}")
        end

      {:ok, _probe, %{count: 0}} ->
        conn
        |> put_flash(:error, "Nothing to export — this view has no events.")
        |> redirect(to: ~p"/app/#{account}/audit?#{filter_params}")

      {:error, reason} ->
        Logger.error("audit CSV count failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "The CSV could not be prepared. Nothing was downloaded; try again.")
        |> redirect(to: ~p"/app/#{account}/audit?#{filter_params}")
    end
  end

  defp begin_csv_download(conn, subject, account, opts, filter_params) do
    case Audit.start_csv_export(subject) do
      {:ok, access} ->
        prepare_csv(conn, subject, account, opts, filter_params, access)

      {:error, :audit_csv_export_already_used} ->
        csv_already_used(conn, account)

      {:error, :audit_csv_export_in_progress} ->
        conn
        |> put_flash(
          :info,
          "A one-time audit CSV is already being prepared. Try again after 30 minutes if it did not finish."
        )
        |> redirect(to: ~p"/app/#{account}/audit")

      {:error, :audit_csv_export_not_available} ->
        conn
        |> put_flash(:info, "Repeated CSV export is available on the Team plan.")
        |> redirect(to: ~p"/app/#{account}/settings/billing")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "You don't have permission to export the audit log.")
        |> redirect(to: ~p"/app/#{account}")
    end
  end

  defp csv_already_used(conn, account) do
    conn
    |> put_flash(
      :error,
      "The one-time audit CSV was already created. Upgrade to Team for repeated exports."
    )
    |> redirect(to: ~p"/app/#{account}/audit")
  end

  defp oversized_export_message(count, :repeatable) do
    "This view has #{count} events — the CSV download caps at #{max_rows()}. " <>
      "Narrow the filters, or pull the full trail through the SIEM export API."
  end

  defp oversized_export_message(count, :one_time) do
    "This view has #{count} events — the CSV download caps at #{max_rows()}. " <>
      "Narrow the filters and try again; this did not use the one-time download."
  end

  # The path is System.tmp_dir! plus a server-generated UUID; no request value
  # reaches send_download or cleanup. Sobelow cannot follow that construction.
  # sobelow_skip ["Traversal.FileModule", "Traversal.SendDownload"]
  defp prepare_csv(conn, subject, account, opts, filter_params, access) do
    filename =
      "audit-#{account.slug}-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")}.csv"

    path = Path.join(System.tmp_dir!(), "emisar-audit-#{Ecto.UUID.generate()}.csv")

    try do
      with {:ok, count} <- write_csv(path, subject, opts),
           {:ok, _receipt} <- Audit.finish_csv_export(subject, access, opts, count) do
        send_download(conn, {:file, path}, filename: filename, content_type: "text/csv")
      else
        {:error, reason} ->
          csv_preparation_failed(conn, subject, account, access, filter_params, reason)
      end
    rescue
      exception ->
        _ = Audit.cancel_csv_export(subject, access)
        reraise exception, __STACKTRACE__
    after
      _ = File.rm(path)
    end
  end

  defp csv_preparation_failed(conn, subject, account, access, filter_params, reason) do
    _ = Audit.cancel_csv_export(subject, access)
    log_csv_preparation_failure(reason)

    conn
    |> put_flash(:error, csv_preparation_error(reason))
    |> redirect(to: ~p"/app/#{account}/audit?#{filter_params}")
  end

  defp csv_preparation_error(:row_cap_exceeded) do
    "The audit log changed while the CSV was being prepared and is now too large. " <>
      "Narrow the filters and try again."
  end

  defp csv_preparation_error(:byte_cap_exceeded),
    do: "This CSV is too large to prepare safely. Narrow the filters and try again."

  defp csv_preparation_error(:snapshot_changed) do
    "The audit log changed while the CSV was being prepared. Review the filters and try again."
  end

  defp csv_preparation_error(:reservation_mismatch) do
    "Another one-time CSV request replaced this one before it finished. " <>
      "Wait for that request to complete."
  end

  defp csv_preparation_error(_reason),
    do: "The CSV could not be prepared. Nothing was downloaded; try again."

  defp log_csv_preparation_failure(reason)
       when reason in [
              :row_cap_exceeded,
              :byte_cap_exceeded,
              :snapshot_changed,
              :reservation_mismatch
            ],
       do: :ok

  defp log_csv_preparation_failure(reason) do
    Logger.error("audit CSV preparation did not complete: #{inspect(reason)}")
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

  # Only prepare_csv's server-generated temporary path reaches these file calls.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_csv(path, subject, opts) do
    case File.open(path, [:write, :binary, :exclusive], fn io ->
           with :ok <- File.chmod(path, 0o600),
                {:ok, bytes} <- write_csv_data(io, csv_header(), 0),
                {:ok, count, _bytes} <- write_pages(io, subject, opts, nil, 0, 0, bytes) do
             {:ok, count}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:temporary_file, reason}}
    end
  end

  defp write_pages(io, subject, opts, cursor, pages, count, bytes) do
    if pages >= max_pages() do
      {:error, :row_cap_exceeded}
    else
      write_page(io, subject, opts, cursor, pages, count, bytes)
    end
  end

  defp write_page(io, subject, opts, cursor, pages, count, bytes) do
    # count: false — a walk must not re-count the whole filtered set per page
    # (the up-front probe already counted once).
    page_opts = opts |> Keyword.put(:page, page(cursor)) |> Keyword.put(:count, false)

    case Audit.list_events(subject, page_opts) do
      {:ok, [], _meta} when count == 0 ->
        {:error, :snapshot_changed}

      {:ok, [], _meta} ->
        {:ok, count, bytes}

      {:ok, events, meta} ->
        next_count = count + length(events)

        if next_count > max_rows() do
          {:error, :row_cap_exceeded}
        else
          case write_csv_data(io, Enum.map(events, &csv_row/1), bytes) do
            {:ok, bytes} ->
              case meta.next_page_cursor do
                nil ->
                  {:ok, next_count, bytes}

                next ->
                  write_pages(io, subject, opts, next, pages + 1, next_count, bytes)
              end

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_csv_data(io, data, bytes) do
    next_bytes = bytes + IO.iodata_length(data)

    if next_bytes > max_bytes() do
      {:error, :byte_cap_exceeded}
    else
      case :file.write(io, data) do
        :ok -> {:ok, next_bytes}
        {:error, reason} -> {:error, {:temporary_file, reason}}
      end
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
      event.event_type |> Audit.event_outcome() |> Atom.to_string(),
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
