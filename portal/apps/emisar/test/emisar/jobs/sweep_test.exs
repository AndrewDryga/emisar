defmodule Emisar.Jobs.SweepTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Emisar.Jobs.Sweep

  defp page(rows) do
    fn limit, cursor ->
      rows
      |> Enum.drop_while(&(cursor != nil and &1.id <= cursor))
      |> Enum.take(limit)
    end
  end

  describe "reduce_pages/4" do
    test "folds every page, keyed on the last row's id" do
      rows = Enum.map(1..7, &%{id: &1})

      assert Sweep.reduce_pages(3, 0, page(rows), fn row, sum -> sum + row.id end) == 28
    end

    test "a raising row is skipped and the sweep reaches every later row" do
      rows = Enum.map(1..5, &%{id: &1})

      reduce_row = fn
        %{id: 2}, _swept -> raise "poisoned account"
        row, swept -> [row.id | swept]
      end

      {swept, log} =
        with_log(fn -> Sweep.reduce_pages(2, [], page(rows), reduce_row) end)

      # The page is keyset-ordered and every tick restarts at the head, so a
      # raising row that killed the tick would starve rows 3-5 forever.
      assert Enum.sort(swept) == [1, 3, 4, 5]
      assert log =~ "sweep.row_failed row=2"
      assert log =~ "job=Emisar.Jobs.SweepTest"
      assert log =~ "error=RuntimeError"
      refute log =~ "poisoned account"
    end
  end

  describe "each_row/3" do
    test "walks every row for its side effects and returns :ok" do
      rows = Enum.map(1..4, &%{id: &1})
      test_pid = self()

      assert Sweep.each_row(2, page(rows), &send(test_pid, {:swept, &1.id})) == :ok

      for id <- 1..4, do: assert_received({:swept, ^id})
    end

    test "a raising row does not stop the walk" do
      rows = Enum.map(1..3, &%{id: &1})
      test_pid = self()

      handle_row = fn
        %{id: 1} -> raise "poisoned account"
        row -> send(test_pid, {:swept, row.id})
      end

      log = with_log(fn -> assert Sweep.each_row(2, page(rows), handle_row) == :ok end) |> elem(1)

      assert_received {:swept, 2}
      assert_received {:swept, 3}

      # The fold `each_row/3` builds lives in Sweep, so the signal has to be
      # named after the caller's own row handler or every sweep blames Sweep.
      assert log =~ "job=Emisar.Jobs.SweepTest"
    end
  end
end
