defmodule Emisar.Runs.Jobs.FleetObservabilityTest do
  @moduledoc """
  The cluster-singleton emitter of the `fleet.observability` line that the GCP
  fleet-drop and dispatch-backlog log-based metrics watch. `async: false` because
  it raises the global Logger level to `:info` (the test env defaults to
  `:warning`) to observe the info line.

  The metadata VALUES are the alert contract: the GCP metrics filter on
  `jsonPayload.connected_runners` / `jsonPayload.pending_dispatch_depth` as JSON
  numbers, so each test captures the raw `:logger` event and asserts the keys hold
  INTEGERS — a renamed key, a dropped key, or a stringified count would pass a
  message-only assertion while silently killing both alerts.
  """
  use Emisar.DataCase, async: false
  import ExUnit.CaptureLog
  alias Emisar.Fixtures
  alias Emisar.Runners
  alias Emisar.Runs.Jobs.FleetObservability

  defmodule LogEventCapture do
    @moduledoc false
    def log(%{msg: {:string, message}, meta: meta}, %{config: %{test_pid: test_pid}}),
      do: send(test_pid, {:log_event, IO.chardata_to_string(message), meta})

    def log(_event, _config), do: :ok
  end

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)

    # A fixed id is safe: async: false serializes this module and on_exit
    # removes the handler before the next test adds it again.
    handler_id = :fleet_observability_log_capture
    :ok = :logger.add_handler(handler_id, LogEventCapture, %{config: %{test_pid: self()}})

    on_exit(fn ->
      _ = :logger.remove_handler(handler_id)
      Logger.configure(level: previous)
    end)

    :ok
  end

  # connected_runners comes from Phoenix.Presence, which lives outside the DB
  # sandbox: entries other tests register are still there when this module runs,
  # and `async: false` does not undo them. So the connected count is asserted as
  # a DELTA against a baseline read immediately before the arrangement.
  # pending_dispatch_depth is a plain DB count and stays absolute.

  # The emitter logs UNCONDITIONALLY every tick, including the zero state — the
  # fleet-drop alert needs a "connected_runners = 0" data point, which is
  # indistinguishable from a gap in logging if the line is only emitted when the
  # fleet is up. The keys must also hold integers: the GCP metrics parse them as
  # JSON numbers, so a stringified count kills both alerts silently.
  test "execute/1 emits every tick with integer counts, whatever the fleet size" do
    log = capture_log(fn -> assert FleetObservability.execute([]) == :ok end)
    assert log =~ "fleet.observability"

    assert_receive {:log_event, "fleet.observability", meta}
    assert is_integer(meta[:connected_runners])
    assert meta[:pending_dispatch_depth] === 0
  end

  test "execute/1 emits the connected-runner count and pending-dispatch depth" do
    baseline = Runners.connection_counts().connected

    # Each pending run creates its own runner, connected by fixture default.
    Fixtures.Runs.create_run(status: :pending)
    Fixtures.Runs.create_run(status: :pending)

    log = capture_log(fn -> assert FleetObservability.execute([]) == :ok end)
    assert log =~ "fleet.observability"

    assert_receive {:log_event, "fleet.observability", meta}
    assert meta[:connected_runners] === baseline + 2
    assert meta[:pending_dispatch_depth] === 2
  end
end
