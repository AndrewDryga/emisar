defmodule EmisarWeb.TimeHelpers do
  use Phoenix.Component

  @moduledoc """
  Shared formatters for dates/times in the UI. One place so every
  page renders timestamps the same way.

      <span>{relative_time(@run.inserted_at)}</span>     # "3m ago"
      <span>{absolute_time(@run.inserted_at)}</span>     # "May 21, 14:03 UTC"

  All formatters tolerate `nil` and `%NaiveDateTime{}` in addition to
  `%DateTime{}`. `nil` renders as the configurable `placeholder`
  (defaults to `"—"`).
  """

  @doc """
  A short relative timestamp:

      just now  /  3m ago  /  4h ago  /  2d ago  /  May 18

  Falls back to `placeholder` for nil.
  """
  def relative_time(value, opts \\ [])

  def relative_time(nil, opts), do: Keyword.get(opts, :placeholder, "—")

  def relative_time(%DateTime{} = dt, _opts) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff >= -5 and diff < 5 -> "just now"
      diff >= 0 -> past_label(diff, dt)
      true -> future_label(-diff, dt)
    end
  end

  def relative_time(%NaiveDateTime{} = ndt, opts),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> relative_time(opts)

  defp past_label(diff, dt) do
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  defp future_label(diff, dt) do
    cond do
      diff < 60 -> "in #{diff}s"
      diff < 3_600 -> "in #{div(diff, 60)}m"
      diff < 86_400 -> "in #{div(diff, 3_600)}h"
      diff < 604_800 -> "in #{div(diff, 86_400)}d"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  @doc """
  Absolute UTC timestamp, "May 21, 14:03 UTC" style.
  """
  def absolute_time(value, opts \\ [])

  def absolute_time(nil, opts), do: Keyword.get(opts, :placeholder, "—")

  def absolute_time(%DateTime{} = dt, _opts),
    do: Calendar.strftime(dt, "%b %-d, %H:%M UTC")

  def absolute_time(%NaiveDateTime{} = ndt, opts),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> absolute_time(opts)

  @doc """
  Formats a duration given in milliseconds: `"1.3s"`, `"312ms"`, `"4m"`.
  Useful for run.duration_ms.
  """
  def format_duration(nil), do: "—"
  def format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  def format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  def format_duration(ms), do: "#{div(ms, 60_000)}m"

  @doc """
  Common "last used X ago" formatter. nil → "never" (the column the LV
  expects when a key/runner has never been touched); a timestamp gets
  the standard `relative_time/2` rendering.
  """
  def last_used(nil), do: "never"
  def last_used(ts), do: relative_time(ts)

  @doc """
  Humanizes an Ecto.Changeset (or a list of `{field, {msg, opts}}` errors)
  into a readable string for flash messages. Replaces ad-hoc
  `inspect(changeset.errors)` which leaks raw Elixir syntax to the user
  (e.g. `[email: {"can't be blank", []}]`).

      iex> humanize_errors(%Ecto.Changeset{errors: [email: {"can't be blank", []}]})
      "email can't be blank"
  """
  def humanize_errors(%Ecto.Changeset{errors: errors}), do: humanize_errors(errors)

  def humanize_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(fn {field, {msg, opts}} ->
      # Substitute %{count}-style template variables from opts the
      # same way Ecto's traverse_errors/2 does.
      msg =
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      "#{field} #{msg}"
    end)
    |> Enum.join("; ")
  end

  def humanize_errors(_), do: "Something went wrong"

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
  attr :mode, :atom, default: :absolute, values: [:absolute, :relative]
  attr :placeholder, :string, default: "—"
  attr :class, :string, default: nil

  def local_time(%{value: nil} = assigns) do
    ~H"<span class={@class}>{@placeholder}</span>"
  end

  def local_time(assigns) do
    dt = to_datetime(assigns.value)

    assigns =
      assigns
      |> assign(:iso, DateTime.to_iso8601(dt))
      |> assign(
        :fallback,
        case assigns.mode do
          :relative -> relative_time(dt)
          :absolute -> absolute_time(dt)
        end
      )

    ~H"""
    <time
      id={"t-#{System.unique_integer([:positive])}"}
      phx-hook="LocalTime"
      phx-update="ignore"
      datetime={@iso}
      data-format={Atom.to_string(@mode)}
      class={@class}
    >
      {@fallback}
    </time>
    """
  end

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
