defmodule EmisarWeb.RunnerSocketDrain do
  @moduledoc """
  Graceful shutdown coordinator for cloud → runner WebSocket connections.

  Sits in the supervision tree below `EmisarWeb.Endpoint`, so on SIGTERM
  it terminates BEFORE the Endpoint tears every socket down at once.
  Its `terminate/2` broadcasts a `:drain` signal on the
  `runner_socket_drain` PubSub topic. Each `EmisarWeb.RunnerSocket`
  process subscribes to that topic at init; on `:drain` it pushes a
  `shutdown` envelope to the runner (so the runner knows to resync state
  after reconnecting, not silently retry an outbound queue with the
  cloud's old state) and stops normally.

  The terminate call sleeps for up to `@drain_window_ms` to give the
  sockets time to flush their outbound queue before BEAM teardown
  forces the WebSocket transport closed.
  """

  use GenServer
  require Logger

  @drain_topic "runner_socket_drain"
  @drain_window_ms 2_000

  def drain_topic, do: @drain_topic

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    # Trap exit so OTP routes shutdown through `terminate/2` instead of
    # killing the process. Without this, the broadcast below never fires.
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("draining runner sockets before shutdown")

    :ok = Emisar.PubSub.broadcast(@drain_topic, :runner_socket_drain)

    # Give the sockets time to flush the shutdown envelope onto the wire
    # before BEAM teardown closes the transports.
    Process.sleep(@drain_window_ms)

    :ok
  end
end
