defmodule Emisar.CalendarMonth do
  @moduledoc """
  Calendar-month boundaries in UTC, for the monthly account-health report:
  the start of the month a moment falls in, and the prior full month's
  `[start, end)` window.
  """

  @midnight ~T[00:00:00.000000]

  @doc "Midnight (UTC) on the first day of the month `at` falls in."
  def month_start(%DateTime{} = at) do
    at
    |> DateTime.to_date()
    |> Date.beginning_of_month()
    |> DateTime.new!(@midnight, "Etc/UTC")
  end

  @doc """
  The prior full calendar month as a half-open `{start, next_start}` window —
  `next_start` is this month's start, so the range excludes the current month.
  """
  def previous_month(%DateTime{} = at) do
    this_month_start = month_start(at)

    previous_month_start =
      this_month_start
      |> DateTime.to_date()
      |> Date.add(-1)
      |> Date.beginning_of_month()
      |> DateTime.new!(@midnight, "Etc/UTC")

    {previous_month_start, this_month_start}
  end
end
