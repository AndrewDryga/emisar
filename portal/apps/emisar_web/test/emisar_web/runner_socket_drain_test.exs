defmodule EmisarWeb.RunnerSocketDrainTest do
  @moduledoc """
  The graceful-shutdown coordinator. Two things are load-bearing:
  the process traps exits (without it `terminate/2` never runs on
  SIGTERM), and terminate broadcasts on the exact topic the runner
  sockets subscribe to.
  """
  use ExUnit.Case, async: true

  alias EmisarWeb.RunnerSocketDrain

  test "the supervised process traps exits so terminate/2 fires" do
    pid = Process.whereis(RunnerSocketDrain)
    assert is_pid(pid)
    assert Process.info(pid, :trap_exit) == {:trap_exit, true}
  end

  test "terminate broadcasts :runner_socket_drain on the shared topic" do
    :ok = Phoenix.PubSub.subscribe(Emisar.PubSub.Server, RunnerSocketDrain.drain_topic())

    # Direct call — the drain window sleep makes this take ~2s, which is
    # the documented flush window, not a test smell.
    assert :ok = RunnerSocketDrain.terminate(:shutdown, %{})

    assert_receive :runner_socket_drain
  end
end
