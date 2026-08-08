defmodule EmisarWeb.TimeHelpers do
  @moduledoc """
  Shared view formatters — timestamps, durations, JSON, audit labels,
  and changeset errors. One place so every page renders the same way.
  Formatting only: it takes scalars and plain tuples, never a domain struct
  or a loaded/unloaded association (attribution facts come from
  `Emisar.Runs.run_who_via/1` and `Emisar.Runbooks.execution_who_via/1`).

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
    # One `now` for both the diff and the year comparison — reading the clock
    # twice can straddle midnight on New Year's Eve and print the wrong form.
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff >= -5 and diff < 5 -> "just now"
      diff >= 0 -> past_label(diff, datetime, now)
      true -> future_label(-diff, datetime, now)
    end
  end

  def relative_time(%NaiveDateTime{} = ndt, opts),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> relative_time(opts)

  # Beyond a week it's an absolute date, and the year is what makes it readable:
  # a bare "Jul 2" from a previous year reads as this one. The test is the
  # CALENDAR year, not an elapsed-days threshold — a 365-day window kept the year
  # off "Dec 20" viewed in January, which is exactly the case the year is for.
  defp past_label(diff, datetime, now) do
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> absolute_date(datetime, now)
    end
  end

  defp future_label(diff, datetime, now) do
    cond do
      diff < 60 -> "in #{diff}s"
      diff < 3_600 -> "in #{div(diff, 60)}m"
      diff < 86_400 -> "in #{div(diff, 3_600)}h"
      diff < 604_800 -> "in #{div(diff, 86_400)}d"
      true -> absolute_date(datetime, now)
    end
  end

  defp absolute_date(%DateTime{year: year} = datetime, %DateTime{year: year}),
    do: Calendar.strftime(datetime, "%b %-d")

  defp absolute_date(datetime, _now), do: Calendar.strftime(datetime, "%b %-d, %Y")

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

  # Compile-time map keyed off `Emisar.Audit.known_event_type_values/0` — the
  # single source of truth for known event types. Adding a new event type only
  # requires editing that one list, and the human-facing label here is derived
  # automatically.
  @event_type_labels Emisar.Audit.known_event_type_values() |> Map.new()
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

  attr :id, :string,
    default: nil,
    doc:
      "A ROW-STABLE id for a SINGLE-render list/stream row (e.g. id={\"when-\#{event.id}\"}) so morphdom keeps each <time> paired with its own row across a filter patch. Omit it for singletons and for a responsive LiveTable :col (which renders each cell twice) — the fallback id is unique per render."

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
    <%!-- id: a caller-supplied ROW-STABLE id lets morphdom match this <time> to its
         own row across a filter patch (no churn, no cross-row bleed). Without one we
         fall back to a per-RENDER unique id — NOT a value-derived hash: a responsive
         LiveTable renders each row's cell TWICE (desktop <td> + mobile card), so any
         value-based id would be a duplicate DOM id there. What actually fixes the
         stale-render bleed is the ABSENCE of phx-update="ignore" below — the hook's
         updated() re-reads datetime on every patch, so a fresh id is harmless. --%>
    <time
      id={@id || "t-#{System.unique_integer([:positive])}"}
      phx-hook="LocalTime"
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
  The single-line accountable actor label for `source_badge`, from the
  `{who, via}` a domain projection returns (`Emisar.Runs.run_who_via/1`,
  `Emisar.Runbooks.execution_who_via/1`): the human when one resolved, else the
  dispatch channel, else the em-dash placeholder. The icon beside it already
  communicates the channel, so a resolved human is never followed by redundant
  `via <channel>` text. Formatting only — who counts as the accountable human
  is the domain's call, never this module's.
  """
  def accountable_actor_label({nil, nil}), do: "—"
  def accountable_actor_label({nil, via}), do: via
  def accountable_actor_label({who, _via}), do: who

  @doc "Humanized run source (`:mcp` → `LLM agent`, …) — the sidebar/filter noun."
  def format_source(:operator), do: "Operator"
  def format_source(:mcp), do: "LLM agent"
  def format_source(:runbook), do: "Runbook"
  def format_source(_), do: "—"
end
