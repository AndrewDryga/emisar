defmodule Emisar.Jobs.Executors.GloballyUniqueTest do
  use ExUnit.Case, async: false
  alias Emisar.Jobs.Executors.GloballyUnique

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
    {:ok, pid} =
      GloballyUnique.start_link(
        {ExecutingJob, :timer.hours(1), initial_delay: 0, test_pid: self()}
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert_receive :executed, 500
  end

  test "a disabled job is not started" do
    assert :ignore =
             GloballyUnique.start_link(
               {ExecutingJob, :timer.hours(1), enabled: false, test_pid: self()}
             )
  end
end
