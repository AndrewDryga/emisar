defmodule Emisar.ConcurrentProfileFormatter do
  @moduledoc false

  use GenServer

  @default_count 20

  def options(options) do
    if System.get_env("EMISAR_TEST_PROFILE") == "1" do
      Keyword.merge(options,
        formatters: [ExUnit.CLIFormatter, __MODULE__],
        emisar_profile_count: @default_count
      )
    else
      options
    end
  end

  @impl GenServer
  def init(options) do
    {:ok, %{count: Keyword.fetch!(options, :emisar_profile_count), tests: []}}
  end

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    tests =
      [test | state.tests]
      |> Enum.sort_by(&{-&1.time, inspect(&1.module), &1.description})
      |> Enum.take(state.count)

    {:noreply, %{state | tests: tests}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    IO.puts("\nSlowest #{length(state.tests)} tests (normal concurrency preserved):")

    Enum.each(state.tests, fn test ->
      milliseconds = Float.round(test.time / 1_000, 1)
      file = test.tags[:file] |> Path.relative_to_cwd()

      IO.puts(
        "  #{milliseconds}ms #{inspect(test.module)} #{test.description} [#{file}:#{test.tags[:line]}]"
      )
    end)

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
