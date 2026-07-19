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
  alias Emisar.Fixtures
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
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      user = Fixtures.Users.create_user()

      _membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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

      {:ok, _} = Fixtures.Runs.finish(run, %{"status" => "success", "duration_ms" => 6})

      assert_receive {:run_finished, %{count: 1, duration_ms: 6}, %{status: :success}}
    end
  end
end
