defmodule Emisar.RunsTelemetryTest do
  @moduledoc """
  Run-outcome telemetry — its own `async: false` module on purpose.

  The test attaches a GLOBAL `[:emisar, :run, :finished]` handler and asserts on
  the ABSENCE of an outcome event (`refute_received`). That event is tagged only
  by the low-cardinality `status` (no run/account id to filter on — see
  `Emisar.Telemetry`), so a concurrent async test's terminal transition would
  leak its finished event into this handler and trip the refute (~1/11 runs).
  Sync modules run after every async module has finished and one at a time, so
  this handler only ever sees its own run's event.
  """
  use Emisar.DataCase, async: false

  import Emisar.Fixtures

  alias Emisar.Runs

  defp base_attrs(account_id, runner_id) do
    %{
      runner_id: runner_id,
      action_id: "linux.uptime",
      args: %{},
      reason: "test",
      source: "operator",
      account_id: account_id
    }
  end

  describe "run outcome telemetry" do
    test "a terminal transition emits [:emisar, :run, :finished], tagged by status" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      handler = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler,
        [:emisar, :run, :finished],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:run_finished, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, :running, run} = Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      # The intermediate :running transition must NOT count an outcome.
      refute_received {:run_finished, _, _}

      {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 6})

      assert_receive {:run_finished, %{count: 1, duration_ms: 6}, %{status: :success}}
    end
  end
end
