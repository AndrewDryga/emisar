defmodule Emisar.ConcurrencyCaseTest do
  use Emisar.ConcurrencyCase, async: false
  import ExUnit.CaptureLog

  test "an awaited writer failure still exits and runs fixture cleanup" do
    log =
      capture_log(fn ->
        task = unboxed_task(fn -> raise "deliberate concurrency fixture failure" end)

        reason =
          catch_exit(
            try do
              Task.await(task)
            after
              send(self(), :fixture_cleaned)
            end
          )

        assert inspect(reason) =~ "deliberate concurrency fixture failure"
        assert_received :fixture_cleaned
      end)

    assert log =~ "deliberate concurrency fixture failure"
  end
end
