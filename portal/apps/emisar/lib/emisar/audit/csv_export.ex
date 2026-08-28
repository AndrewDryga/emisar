defmodule Emisar.Audit.CSVExport do
  @moduledoc """
  Materializes the operator-facing audit CSV — the domain half of the console's
  Export button, reached through `Audit.prepare_csv_export/2`.

  This lived inside the web controller: the caps, the snapshot check, the CSV
  encoding whose column order freezes at 1.0, and the export receipt are domain
  behavior, and the web is an adapter. The controller keeps what is genuinely
  web — param translation, flashes, `send_download`, and deleting the file once
  it has been sent.

  The file is built completely BEFORE the caller commits response headers, so a
  late page failure can never look like a valid, cleanly terminated CSV. The
  byte cap also keeps an adversarial set of maximum-sized audit rows from
  filling the node's temporary volume.
  """

  alias Emisar.{Audit, Config}
  alias Emisar.Auth.Subject

  @page_limit 100
  @default_max_bytes 256 * 1024 * 1024

  defp max_rows, do: Config.get_env(:emisar, :audit_csv_max_rows, 100_000)

  defp max_bytes, do: Config.get_env(:emisar, :audit_csv_max_bytes, @default_max_bytes)

  defp max_pages, do: div(max_rows() + @page_limit - 1, @page_limit)

  @doc """
  Builds the complete bounded CSV for `opts` into a fresh 0600 temp file and
  records the export receipt. Returns `{:ok, %{path: path, count: count}}` —
  the CALLER owns deleting `path` once it has been sent — or
  `{:error, :nothing_to_export | :row_cap_exceeded | :byte_cap_exceeded |
  :snapshot_changed | term}`. An over-cap view refuses with everything the
  caller's message needs: `{:error, {:too_many_rows, %{count: count, max: max}}}`.

  ONE exact up-front count decides honestly: within bounds → write it all;
  over → refuse, never a truncated file. Authorization and the plan gate are
  `Audit.list_events_for_export/2`'s, enforced on every page read.
  """
  def export(%Subject{} = subject, opts) do
    probe_opts = opts |> Keyword.put(:page, limit: 1) |> Keyword.put(:count, true)

    case Audit.list_events_for_export(subject, probe_opts) do
      {:ok, _probe, %{count: 0}} ->
        {:error, :nothing_to_export}

      {:ok, _probe, %{count: count}} when count > 0 ->
        if count <= max_rows() do
          materialize(subject, opts, count)
        else
          {:error, {:too_many_rows, %{count: count, max: max_rows()}}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The path is System.tmp_dir! plus a server-generated UUID; no caller value
  # reaches the file operations. Sobelow cannot follow that construction.
  # sobelow_skip ["Traversal.FileModule"]
  defp materialize(subject, opts, expected_count) do
    path = Path.join(System.tmp_dir!(), "emisar-audit-#{Ecto.UUID.generate()}.csv")

    with {:ok, count} <- write_csv(path, subject, opts),
         :ok <- ensure_snapshot_count(count, expected_count),
         {:ok, _receipt} <- Audit.record_export(subject, opts, count) do
      {:ok, %{path: path, count: count}}
    else
      {:error, reason} ->
        _ = File.rm(path)
        {:error, reason}
    end
  end

  defp ensure_snapshot_count(count, count), do: :ok
  defp ensure_snapshot_count(_count, _expected_count), do: {:error, :snapshot_changed}

  # Only materialize's server-generated temporary path reaches these file calls.
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

    case Audit.list_events_for_export(subject, page_opts) do
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

  # `id` leads. It is the ONLY value shared with the NDJSON export, so it is what
  # makes the two joinable — the concrete case being an auditor who downloads
  # this file while the security team pulls the same window from their SIEM.
  # Without it there was no join key at all: the two share no identifier, and
  # their timestamps differ in name, format AND precision, so even a lossy
  # match on time failed. Column ORDER freezes at 1.0, so a leading column has
  # to be chosen now — added later it would break every positional parser.
  defp csv_header do
    "id,occurred_at_utc,event_type,severity,actor_kind,actor_id,actor_label," <>
      "target_kind,target_id,target_label,ip_address,auth_method,request_id,payload\r\n"
  end

  defp csv_row(event) do
    [
      event.id,
      forensic_time(event.occurred_at),
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

  # The console's forensic timestamp format, spelled here rather than through
  # the web's TimeHelpers — the domain cannot call the web, and the CSV's
  # occurred_at_utc format freezes at 1.0 with the column order, so it must not
  # drift with a display helper anyway.
  defp forensic_time(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp formula_safe(value) do
    if String.starts_with?(String.trim_leading(value), ["=", "+", "-", "@"]) do
      "\t" <> value
    else
      value
    end
  end
end
