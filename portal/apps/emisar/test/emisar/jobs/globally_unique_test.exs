defmodule Emisar.Jobs.Executors.GloballyUniqueTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Emisar.Jobs.Executors.GloballyUnique

  @wait 2_000

  defmodule DeclaredJob do
    use Emisar.Jobs.Job,
      otp_app: :emisar,
      every: :timer.minutes(5),
      initial_delay: :timer.seconds(3),
      executor: GloballyUnique

    @impl GloballyUnique
    def execute(_config), do: :ok
  end

  defmodule ExecutingJob do
    @behaviour GloballyUnique

    @impl GloballyUnique
    def execute(config) do
      send(Keyword.fetch!(config, :test_pid), :executed)
      :ok
    end
  end

  defmodule ReclaimingJob do
    @behaviour GloballyUnique

    @impl GloballyUnique
    def execute(config) do
      send(Keyword.fetch!(config, :test_pid), :executed)
      :ok
    end
  end

  defmodule FailingJob do
    @behaviour GloballyUnique

    @impl GloballyUnique
    def execute(_config), do: raise("secret-shaped detail must not be logged")
  end

  test "declared jobs preserve their configured interval and initial delay" do
    assert %{
             id: DeclaredJob,
             start: {GloballyUnique, :start_link, [{DeclaredJob, interval, config}]}
           } =
             DeclaredJob.child_spec([])

    assert interval == :timer.minutes(5)
    assert Keyword.fetch!(config, :initial_delay) == :timer.seconds(3)
  end

  test "an enabled leader executes its initial tick" do
    start_supervised!(
      {GloballyUnique, {ExecutingJob, :timer.hours(1), initial_delay: 0, test_pid: self()}}
    )

    assert_receive :executed, @wait
  end

  test "a disabled job is not started" do
    assert GloballyUnique.start_link(
             {ExecutingJob, :timer.hours(1), enabled: false, test_pid: self()}
           ) == :ignore
  end

  test "re-acquiring leadership replaces the tick timer instead of adding a second chain" do
    start_supervised!(
      {GloballyUnique, {ReclaimingJob, :timer.hours(1), initial_delay: 0, test_pid: self()}}
    )

    assert_receive :executed, @wait
    leader = :global.whereis_name({GloballyUnique, ReclaimingJob})
    %{role: :leader, tick_ref: leader_ref} = :sys.get_state(leader)
    assert is_integer(Process.read_timer(leader_ref))

    # The flap the module's own comment says it has seen in production: the name
    # goes, then this process claims it back.
    :global.unregister_name({GloballyUnique, ReclaimingJob})
    send(leader, :claim)

    assert_receive :executed, @wait
    %{role: :leader, tick_ref: reclaimed_ref} = :sys.get_state(leader)

    # One chain, not two: the pre-flap timer is cancelled rather than left
    # running beside the new one, which is what permanently doubled the job's
    # cadence on that node.
    assert Process.read_timer(leader_ref) == false
    assert is_integer(Process.read_timer(reclaimed_ref))
  end

  test "a failed tick emits a stable redacted operator signal" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    log =
      capture_log(fn ->
        {:ok, pid} = GloballyUnique.start_link({FailingJob, :timer.hours(1), initial_delay: 0})
        assert_receive {:EXIT, ^pid, {%RuntimeError{}, _stacktrace}}, @wait
      end)

    assert log =~ "recurrent_job.failed"
    assert log =~ "job=Emisar.Jobs.Executors.GloballyUniqueTest.FailingJob"
    assert log =~ "error=RuntimeError"
    signal = Enum.find(String.split(log, "\n"), &String.contains?(&1, "recurrent_job.failed"))
    refute signal =~ "secret-shaped detail"
  end
end
