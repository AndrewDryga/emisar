defmodule EmisarWeb.TimeHelpers do
  @moduledoc """
  Shared view formatters — timestamps, durations, JSON, audit labels,
  and changeset errors. One place so every page renders the same way.

      <span>{relative_time(@run.inserted_at)}</span>     # "3m ago"
      <span>{absolute_time(@run.inserted_at)}</span>     # "May 21, 14:03 UTC"

  All formatters tolerate `nil` and `%NaiveDateTime{}` in addition to
  `%DateTime{}`. `nil` renders as the configurable `placeholder`
  (defaults to `"—"`).
  """
  use Phoenix.Component

  @doc """
  A short relative timestamp:

      just now  /  3m ago  /  4h ago  /  2d ago  /  May 18

  Falls back to `placeholder` for nil.
  """
  def relative_time(value, opts \\ [])

  def relative_time(nil, opts), do: Keyword.get(opts, :placeholder, "—")

  def relative_time(%DateTime{} = datetime, _opts) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff >= -5 and diff < 5 -> "just now"
      diff >= 0 -> past_label(diff, datetime)
      true -> future_label(-diff, datetime)
    end
  end

  def relative_time(%NaiveDateTime{} = ndt, opts),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> relative_time(opts)

  # Beyond a week it's an absolute date; within the year "Jul 2", older than a
  # year "Jul 2, 2024" — a bare "Jul 2" from a previous year reads as this one.
  @one_year_seconds 31_536_000

  defp past_label(diff, datetime) do
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      diff < @one_year_seconds -> Calendar.strftime(datetime, "%b %-d")
      true -> Calendar.strftime(datetime, "%b %-d, %Y")
    end
  end

  defp future_label(diff, datetime) do
    cond do
      diff < 60 -> "in #{diff}s"
      diff < 3_600 -> "in #{div(diff, 60)}m"
      diff < 86_400 -> "in #{div(diff, 3_600)}h"
      diff < 604_800 -> "in #{div(diff, 86_400)}d"
      diff < @one_year_seconds -> Calendar.strftime(datetime, "%b %-d")
      true -> Calendar.strftime(datetime, "%b %-d, %Y")
    end
  end

  @doc """
  Absolute UTC timestamp, "May 21, 14:03 UTC" style.
  """
  def absolute_time(value, opts \\ [])

  def absolute_time(nil, opts), do: Keyword.get(opts, :placeholder, "—")

  def absolute_time(%DateTime{} = datetime, _opts),
    do: Calendar.strftime(datetime, "%b %-d, %H:%M UTC")

  def absolute_time(%NaiveDateTime{} = ndt, opts),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> absolute_time(opts)

  @doc """
  Second-precision timestamp for forensic surfaces (the audit trail, decision
  records) — `"2026-07-02 04:44:12 UTC"`. The server fallback is UTC; the
  LocalTime hook re-renders it in the viewer's zone with the same shape.
  """
  def forensic_time(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  def forensic_time(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> forensic_time()

  @doc """
  Formats a duration given in milliseconds: `"1.3s"`, `"312ms"`, `"4m"`.
  Useful for run.duration_ms.
  """
  def format_duration(nil), do: "—"
  def format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  def format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  def format_duration(ms), do: "#{div(ms, 60_000)}m"

  @doc """
  Pretty-prints a map (e.g. a run's args) as indented JSON for `<pre>`
  blocks. `nil` renders as `"{}"`.
  """
  def format_json(nil), do: "{}"
  def format_json(map), do: Jason.encode!(map, pretty: true)

  @doc """
  Friendly label for an audit event type. `runner.connected` →
  `"Runner connected"`. Unknown types are best-effort humanized
  (replace `_`/`.` with space, capitalize first word) so a new event
  type doesn't render as raw machine code in the UI before the table
  here is updated.
  """
  def format_event_type(nil), do: "—"

  def format_event_type(t) when is_binary(t) do
    case Map.get(event_type_labels(), t) do
      nil -> humanize_event(t)
      label -> label
    end
  end

  # Compile-time map keyed off the Audit.Event.Query whitelist — the
  # single source of truth for known event types. Adding a new event
  # type only requires editing one list (Query.@known_event_types) and
  # the human-facing label here is derived automatically.
  @event_type_labels Emisar.Audit.Event.Query.known_event_type_values() |> Map.new()
  defp event_type_labels, do: @event_type_labels

  defp humanize_event(t) do
    t
    |> String.replace(~r/[._]/, " ")
    |> String.split(" ", trim: true)
    |> case do
      [first | rest] -> String.capitalize(first) <> " " <> Enum.join(rest, " ")
      [] -> t
    end
  end

  @doc """
  Render a UTC timestamp as a `<time>` element whose textContent gets
  rewritten by the `LocalTime` JS hook into the viewer's local
  timezone. Non-JS users see the server-rendered UTC fallback.

      <.local_time value={@event.occurred_at} />
      <.local_time value={@run.inserted_at} mode={:relative} />

  `mode`:
    - `:absolute` (default) — "May 30, 18:59 UTC" → "May 30, 14:59"
    - `:relative` — "3h ago" / "Jul 14"

  Tolerates `nil` by rendering `placeholder` (default `"—"`).
  """
  attr :value, :any, required: true
  attr :mode, :atom, default: :absolute, values: [:absolute, :relative, :forensic]
  attr :placeholder, :string, default: "—"
  attr :class, :string, default: nil

  attr :styled_tooltip, :boolean,
    default: false,
    doc:
      "Show the hook's full-stamp tooltip as an INSTANT styled bubble (CSS ::after fed by data-tooltip) instead of the native title — which needs a ~1s still hover and reads as \"no tooltip\". Opt in where the exact stamp matters (the audit trail's relative times)."

  def local_time(%{value: nil} = assigns) do
    ~H"<span class={@class}>{@placeholder}</span>"
  end

  def local_time(assigns) do
    datetime = to_datetime(assigns.value)

    assigns =
      assigns
      |> assign(:iso, DateTime.to_iso8601(datetime))
      |> assign(
        :fallback,
        case assigns.mode do
          :relative -> relative_time(datetime)
          :absolute -> absolute_time(datetime)
          :forensic -> forensic_time(datetime)
        end
      )

    ~H"""
    <time
      id={"t-#{System.unique_integer([:positive])}"}
      phx-hook="LocalTime"
      phx-update="ignore"
      datetime={@iso}
      data-format={Atom.to_string(@mode)}
      data-styled-tooltip={@styled_tooltip}
      class={["tabular-nums", @styled_tooltip && styled_tooltip_classes(), @class]}
    >
      {@fallback}
    </time>
    """
  end

  # The instant tooltip bubble: a pure-CSS ::after fed by attr(data-tooltip)
  # (the LocalTime hook writes it), so it appears on hover with NO dwell delay
  # and matches the float recipe (opaque zinc-900 + ring + heavy shadow).
  defp styled_tooltip_classes do
    "relative cursor-help after:pointer-events-none after:absolute after:bottom-full " <>
      "after:right-0 after:z-20 after:mb-1.5 after:whitespace-nowrap after:rounded-md " <>
      "after:bg-zinc-900 after:px-2.5 after:py-1.5 after:text-[11px] after:text-zinc-200 " <>
      "after:opacity-0 after:shadow-xl after:shadow-black/60 after:ring-1 after:ring-white/10 " <>
      "after:transition-opacity after:content-[attr(data-tooltip)] hover:after:opacity-100"
  end

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  @doc """
  Who initiated a run, as a label. Prefers the MCP client the run was
  dispatched from (clientInfo.name, e.g. "Claude Code"), then the API key's
  name, then the humanized source. Requires `:api_key` preloaded — an
  unloaded association or nil falls back to the source.
  """
  def run_actor(%{client_info: %{"name" => name}}) when is_binary(name) and name != "", do: name
  def run_actor(%{api_key: %{name: name}}) when is_binary(name) and name != "", do: name
  def run_actor(%{source: source}), do: format_source(source)
  def run_actor(_), do: "—"

  @doc "The MCP client version snapshotted on a run, if any (e.g. \"1.2.3\")."
  def client_version(%{client_info: %{"version" => v}}) when is_binary(v) and v != "", do: v
  def client_version(_), do: nil

  @doc "Humanized run source (`:mcp` → `MCP / LLM`, …)."
  def format_source(:operator), do: "Operator"
  def format_source(:mcp), do: "MCP / LLM"
  def format_source(:runbook), do: "Runbook"
  def format_source(:scheduled), do: "Scheduled"
  def format_source(_), do: "—"
end
