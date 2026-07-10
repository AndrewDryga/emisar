defmodule Emisar.CalendarMonthTest do
  use ExUnit.Case, async: true
  alias Emisar.CalendarMonth

  describe "month_start/1" do
    test "returns midnight UTC on the first of the month" do
      assert CalendarMonth.month_start(~U[2026-07-10 14:30:45.123456Z]) ==
               ~U[2026-07-01 00:00:00.000000Z]
    end

    test "is a no-op on a moment already at the month start" do
      assert CalendarMonth.month_start(~U[2026-07-01 00:00:00.000000Z]) ==
               ~U[2026-07-01 00:00:00.000000Z]
    end
  end

  describe "previous_month/1" do
    test "returns the prior full month as a half-open [start, next_start) window" do
      assert CalendarMonth.previous_month(~U[2026-07-10 14:30:45.123456Z]) ==
               {~U[2026-06-01 00:00:00.000000Z], ~U[2026-07-01 00:00:00.000000Z]}
    end

    test "crosses the year boundary in January" do
      assert CalendarMonth.previous_month(~U[2026-01-15 09:00:00.000000Z]) ==
               {~U[2025-12-01 00:00:00.000000Z], ~U[2026-01-01 00:00:00.000000Z]}
    end
  end
end
