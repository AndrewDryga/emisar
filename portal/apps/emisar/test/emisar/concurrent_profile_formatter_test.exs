defmodule Emisar.ConcurrentProfileFormatterTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "keeps and prints only the configured number of slow tests" do
    {:ok, state} = Emisar.ConcurrentProfileFormatter.init(emisar_profile_count: 1)

    fast = test_result("fast test", 12_000, 12)
    slow = test_result("slow test", 145_600, 34)

    {:noreply, state} =
      Emisar.ConcurrentProfileFormatter.handle_cast({:test_finished, fast}, state)

    {:noreply, state} =
      Emisar.ConcurrentProfileFormatter.handle_cast({:test_finished, slow}, state)

    output =
      capture_io(fn ->
        assert {:noreply, ^state} =
                 Emisar.ConcurrentProfileFormatter.handle_cast(
                   {:suite_finished, %{run: 200_000, async: 100_000, load: 0}},
                   state
                 )
      end)

    assert output =~ "Slowest 1 tests (normal concurrency preserved):"
    assert output =~ "145.6ms #{inspect(__MODULE__)} slow test"
    refute output =~ "fast test"
  end

  test "adds itself beside the normal formatter only when profiling is enabled" do
    System.put_env("EMISAR_TEST_PROFILE", "1")
    on_exit(fn -> System.delete_env("EMISAR_TEST_PROFILE") end)

    options = Emisar.ConcurrentProfileFormatter.options(capture_log: true)

    assert options[:capture_log]
    assert options[:formatters] == [ExUnit.CLIFormatter, Emisar.ConcurrentProfileFormatter]
    assert options[:emisar_profile_count] == 20
  end

  defp test_result(description, time, line) do
    %ExUnit.Test{
      name: :profile_test,
      description: description,
      module: __MODULE__,
      state: nil,
      time: time,
      tags: %{file: __ENV__.file, line: line, test_type: :test}
    }
  end
end
