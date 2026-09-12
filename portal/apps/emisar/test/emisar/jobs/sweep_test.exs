defmodule Emisar.Jobs.SweepTest do
  use Emisar.DataCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.Fixtures
  alias Emisar.Jobs.Sweep
  alias Emisar.Runs.ActionRun

  @long_ago ~U[2020-01-01 00:00:00.000000Z]

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

  # The action-run Query with every call reported to the test process before it
  # is delegated, so a test can count the reads a sweep made while the real Repo
  # still selects and deletes the rows. The sweep runs in the test process, so
  # `self()` here is the test.
  defmodule ObservedQuery do
    def prunable_ids(account_id, cutoff, limit) do
      send(self(), {:read, limit})
      ActionRun.Query.prunable_ids(account_id, cutoff, limit)
    end

    def by_ids(ids) do
      send(self(), {:delete, length(ids)})
      ActionRun.Query.by_ids(ids)
    end
  end

  describe "delete_in_batches/4" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account, runner: Fixtures.Runners.create_runner(account_id: account.id)}
    end

    test "a full batch asks again, and the sweep stops at rows the cutoff protects", %{
      account: account,
      runner: runner
    } do
      prunable = for _ <- 1..5, do: finished_run(runner, @long_ago)
      fresh = finished_run(runner, DateTime.utc_now())
      foreign = finished_run(Fixtures.Runners.create_runner(), @long_ago)

      # One batch would report 2; only the recursion reaches all five, and the
      # short third batch stops it without a fourth read.
      assert Sweep.delete_in_batches(ObservedQuery, account.id, cutoff(), 2) == 5
      assert observed_queries() == [read: 2, delete: 2, read: 2, delete: 2, read: 2, delete: 1]

      assert Enum.all?(prunable, &is_nil(Repo.reload(&1)))
      assert Repo.reload(fresh)
      assert Repo.reload(foreign)
    end

    test "a final full batch still costs one read, and a short batch stops", %{
      account: account,
      runner: runner
    } do
      prunable = for _ <- 1..4, do: finished_run(runner, @long_ago)

      # Exactly two full batches: the source is exhausted, but only the empty
      # third read proves it, so the tail must not be silently dropped.
      assert Sweep.delete_in_batches(ObservedQuery, account.id, cutoff(), 2) == 4
      assert observed_queries() == [read: 2, delete: 2, read: 2, delete: 2, read: 2, delete: 0]
      assert Enum.all?(prunable, &is_nil(Repo.reload(&1)))

      # An exhausted source is one empty read, not a full page's worth of asking.
      assert Sweep.delete_in_batches(ObservedQuery, account.id, cutoff(), 2) == 0
      assert observed_queries() == [read: 2, delete: 0]
    end
  end

  # Every query `ObservedQuery` reported since the last call, in call order:
  # `read:` carries the batch size asked for, `delete:` how many ids it got.
  defp observed_queries do
    receive do
      {kind, count} when kind in [:read, :delete] -> [{kind, count} | observed_queries()]
    after
      0 -> []
    end
  end

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -86_400, :second)

  defp finished_run(runner, finished_at) do
    [account_id: runner.account_id, runner_id: runner.id]
    |> Fixtures.Runs.create_run()
    |> change(finished_at: finished_at)
    |> Repo.update!()
  end
end
