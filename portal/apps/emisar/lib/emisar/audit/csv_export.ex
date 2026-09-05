defmodule Emisar.Audit.CSVExport do
  @moduledoc """
  Streams the operator-facing audit CSV — the domain half of the console's
  Export button, reached through `Audit.stream_csv_export/2`.

  The row cap, the CSV encoding whose column order freezes at 1.0, and the
  export receipt are domain behavior, and the web is an adapter: the controller
  keeps param translation, flashes, and the chunked response.

  ONE exact up-front count decides honestly: within the row cap → stream it
  all; over → refuse before a byte leaves, never a truncated file. The walk is
  a descending keyset cursor, so a row logged while it runs sorts ahead of the
  first page and is never reached — the stream yields at most the probed count.
  """

  alias Emisar.{Audit, Config}
  alias Emisar.Auth.Subject

  @page_limit 100

  defp max_rows, do: Config.get_env(:emisar, :audit_csv_max_rows, 100_000)

  @doc """
  The bounded CSV for `opts` as a stream of iodata chunks — the header, then one
  chunk per page — that records the export receipt with the row count once it
  has run, whether it completed or the consumer stopped early. Returns
  `{:ok, stream}` or `{:error, :nothing_to_export | term}`; an over-cap view
  refuses with everything the caller's message needs:
  `{:error, {:too_many_rows, %{count: count, max: max}}}`.

  Authorization and the plan gate are `Audit.list_events_for_export/2`'s,
  enforced on every page read. A page that fails mid-stream raises, so the
  response ends without its terminating chunk instead of looking like a
  complete forensic artifact.
  """
  def stream(%Subject{} = subject, opts) do
    probe_opts = opts |> Keyword.put(:page, limit: 1) |> Keyword.put(:count, true)

    case Audit.list_events_for_export(subject, probe_opts) do
      {:ok, _probe, %{count: 0}} ->
        {:error, :nothing_to_export}

      {:ok, _probe, %{count: count}} when count > 0 ->
        if count <= max_rows(),
          do: {:ok, rows(subject, opts)},
          else: {:error, {:too_many_rows, %{count: count, max: max_rows()}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rows(subject, opts) do
    Stream.resource(
      fn -> {:header, 0} end,
      fn
        {:header, count} -> {[csv_header()], {{:page, nil}, count}}
        {{:page, cursor}, count} -> next_page(subject, opts, cursor, count)
        {:done, count} -> {:halt, {:done, count}}
      end,
      fn {_stage, count} -> _ = Audit.record_export(subject, opts, count) end
    )
  end

  # count: false — a walk must not re-count the whole filtered set per page
  # (the up-front probe already counted once).
  defp next_page(subject, opts, cursor, count) do
    page_opts = opts |> Keyword.put(:page, page(cursor)) |> Keyword.put(:count, false)

    case Audit.list_events_for_export(subject, page_opts) do
      {:ok, [], _meta} ->
        {:halt, {:done, count}}

      {:ok, events, %{next_page_cursor: nil}} ->
        {[Enum.map(events, &csv_row/1)], {:done, count + length(events)}}

      {:ok, events, %{next_page_cursor: next}} ->
        {[Enum.map(events, &csv_row/1)], {{:page, next}, count + length(events)}}

      {:error, reason} ->
        raise "audit CSV page read failed: #{inspect(reason)}"
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
