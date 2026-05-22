defmodule EmisarWeb.TimeHelpers do
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
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  def relative_time(%NaiveDateTime{} = ndt, opts),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> relative_time(opts)

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
end
