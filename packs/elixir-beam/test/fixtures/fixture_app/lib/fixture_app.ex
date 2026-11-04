# A small application with faults planted for the pack's behavior cases. The
# secrets it holds come from the case's declared canaries, and the harness fails
# any case whose result contains one.
defmodule FixtureApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [FixtureApp.Reporter]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: FixtureApp.Supervisor) do
      File.write!("/tmp/fixture_app.ready", "")
      {:ok, pid}
    end
  end
end

# Leaks UDP sockets and starts OS programs with a secret in their argv.
defmodule FixtureApp.Reporter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    secret = System.fetch_env!("FIXTURE_ARGV_SECRET")
    sockets = for _ <- 1..20, do: elem(:gen_udp.open(0), 1)

    programs = [
      Port.open({:spawn, "/bin/sh -c 'exec sleep 100000' fixture --password #{secret}"}, []),
      Port.open({:spawn, "/bin/sh -c 'exec sleep 100000' fixture -p#{secret}"}, []),
      Port.open({:spawn_executable, "/bin/sleep"}, [args: ["100000"]])
    ]

    {:ok, {sockets, programs}}
  end
end
