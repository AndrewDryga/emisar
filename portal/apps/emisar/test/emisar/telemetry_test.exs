defmodule Emisar.TelemetryTest do
  # async: false — telemetry handlers are process-global, so attaching one and
  # asserting on the emit must not race a concurrent test's handler.
  use Emisar.DataCase, async: false

  import Emisar.Fixtures

  alias Emisar.{Approvals, Repo, Runs}

  # Attach a one-shot handler for `event`, run `fun`, return the captured
  # measurements. The metric definition in `EmisarWeb.Telemetry` keys off this
  # exact event path + measurement names, so this guards against a silent drift.
  defp capture(event, fun) do
    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, _meta, pid -> send(pid, {:captured, measurements}) end,
      self()
    )

    fun.()
    assert_received {:captured, measurements}
    :telemetry.detach(handler_id)
    measurements
  end

  describe "measure_approval_queue/0" do
    test "emits [:emisar, :approvals, :pending] with count + oldest_age_seconds" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{},
          status: :pending_approval
        })

      {:ok, _} = Approvals.create_request(run, user_fixture().id, "x")

      measurements =
        capture([:emisar, :approvals, :pending], &Emisar.Telemetry.measure_approval_queue/0)

      assert measurements.count == 1
      assert is_integer(measurements.oldest_age_seconds)
      assert measurements.oldest_age_seconds >= 0
    end
  end

  describe "measure_runner_connections/0" do
    test "emits [:emisar, :runners, :connection] with the four-state tally" do
      # One never-connected runner so the tally is non-empty.
      _ = runner_fixture(connected?: false)

      measurements =
        capture(
          [:emisar, :runners, :connection],
          &Emisar.Telemetry.measure_runner_connections/0
        )

      assert is_integer(measurements.connected)
      assert is_integer(measurements.disconnected)
      assert measurements.never_connected >= 1
      assert is_integer(measurements.disabled)
    end
  end

  describe "measure_oban_queues/0" do
    test "emits the available backlog per configured queue, tagged by queue" do
      # An available job in :default — Repo.insert keeps it queued (Oban's
      # runtime doesn't run it here), so it counts toward the backlog.
      {:ok, _} =
        %{}
        |> Oban.Job.new(worker: Emisar.Workers.BillingSync, queue: "default")
        |> Repo.insert()

      handler = "test-oban-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:emisar, :oban, :queue],
        fn _event, measurements, meta, pid ->
          send(pid, {:oban_queue, meta.queue, measurements.available})
        end,
        self()
      )

      :ok = Emisar.Telemetry.measure_oban_queues()
      :telemetry.detach(handler)

      # The default queue reports its available backlog, tagged by queue. (In
      # test mode `:queues` is `false`, so only queues holding jobs report; in
      # prod every configured queue reports, a drained one at 0.)
      assert_received {:oban_queue, "default", default_available}
      assert default_available >= 1
    end
  end
end
