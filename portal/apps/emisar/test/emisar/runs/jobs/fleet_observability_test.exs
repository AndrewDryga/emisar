defmodule Emisar.Runs.Jobs.FleetObservabilityTest do
  @moduledoc """
  The cluster-singleton emitter of the `fleet.observability` line that the GCP
  fleet-drop and dispatch-backlog log-based metrics watch. `async: false` because
  it raises the global Logger level to `:info` (the test env defaults to
  `:warning`) to observe the info line.
  """
  use Emisar.DataCase, async: false
  import ExUnit.CaptureLog
  alias Emisar.Fixtures
  alias Emisar.Runners
  alias Emisar.Runs
  alias Emisar.Runs.Jobs.FleetObservability

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  # The emitter logs UNCONDITIONALLY every tick, including the zero state — the
  # fleet-drop alert needs a "connected_runners = 0" data point, which is
  # indistinguishable from a gap in logging if the line is only emitted when the
  # fleet is up.
  test "execute/1 emits the signal for an empty fleet (the zero state the drop alert needs)" do
    assert Runners.connection_counts().connected == 0
    assert Runs.count_pending_dispatches() == 0

    log = capture_log(fn -> assert :ok = FleetObservability.execute([]) end)
    assert log =~ "fleet.observability"
  end

  test "execute/1 emits the signal with a pending dispatch backlog present" do
    Fixtures.Runs.create_run(status: :pending)
    Fixtures.Runs.create_run(status: :pending)
    assert Runs.count_pending_dispatches() == 2

    log = capture_log(fn -> assert :ok = FleetObservability.execute([]) end)
    assert log =~ "fleet.observability"
  end
end
