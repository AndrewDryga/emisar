defmodule Emisar.TelemetryTest do
  # async: false — telemetry handlers are process-global, so attaching one and
  # asserting on the emit must not race a concurrent test's handler.
  use Emisar.DataCase, async: false
  alias Emisar.{Approvals, Runs}
  alias Emisar.Fixtures

  # Attach a one-shot handler for `event`, run `fun`, return the captured
  defp capture(event, fun) do
    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, meta, pid -> send(pid, {:captured, measurements, meta}) end,
      self()
    )

    fun.()
    assert_received {:captured, measurements, meta}
    :telemetry.detach(handler_id)
    {measurements, meta}
  end

  # The metric definitions in `EmisarWeb.Telemetry` key off these exact event
  # paths + measurement names, so this guards against silent drift.
  defp capture_measurements(event, fun) do
    {measurements, _meta} = capture(event, fun)
    measurements
  end

  describe "measure_approval_queue/0" do
    test "emits [:emisar, :approvals, :pending] with count + oldest_age_seconds" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      {:ok, _} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")

      measurements =
        capture_measurements(
          [:emisar, :approvals, :pending],
          &Emisar.Telemetry.measure_approval_queue/0
        )

      assert measurements.count == 1
      assert is_integer(measurements.oldest_age_seconds)
      assert measurements.oldest_age_seconds >= 0
    end
  end

  describe "measure_runner_connections/0" do
    test "emits [:emisar, :runners, :connection] with the four-state tally" do
      # One never-connected runner so the tally is non-empty.
      _ = Fixtures.Runners.create_runner(connected?: false)

      measurements =
        capture_measurements(
          [:emisar, :runners, :connection],
          &Emisar.Telemetry.measure_runner_connections/0
        )

      assert is_integer(measurements.connected)
      assert is_integer(measurements.disconnected)
      assert measurements.never_connected >= 1
      assert is_integer(measurements.disabled)
    end
  end

  describe "job telemetry" do
    test "job_finished/2 emits duration tagged by job" do
      {measurements, meta} =
        capture([:emisar, :job, :finished], fn ->
          Emisar.Telemetry.job_finished("Emisar.Runs.Jobs.DispatchTimeout", 123)
        end)

      assert measurements.duration == 123
      assert meta.job == "Emisar.Runs.Jobs.DispatchTimeout"
    end

    test "job_failed/3 emits count + duration tagged by job and kind" do
      {measurements, meta} =
        capture([:emisar, :job, :failed], fn ->
          Emisar.Telemetry.job_failed("Emisar.Billing.Jobs.SyncSubscriptions", :error, 456)
        end)

      assert measurements.count == 1
      assert measurements.duration == 456
      assert meta.job == "Emisar.Billing.Jobs.SyncSubscriptions"
      assert meta.kind == :error
    end
  end
end
