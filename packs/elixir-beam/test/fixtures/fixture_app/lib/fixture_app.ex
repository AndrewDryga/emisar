# A small application with faults planted for the pack's behavior cases. Each
# fault has an ordinary shape an operator would meet. The secrets it holds come
# from the plan's declared canaries, and the harness fails any case whose result
# contains one, so every read proves it leaves state, mailboxes, ETS rows, process
# dictionaries, function arguments, and command lines on the node.
defmodule FixtureApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    secret = System.fetch_env!("FIXTURE_STATE_SECRET")

    children = [
      FixtureApp.Archive,
      FixtureApp.Hog,
      FixtureApp.Plain,
      {FixtureApp.Vault, secret},
      FixtureApp.Inbox,
      {FixtureApp.Sender, System.fetch_env!("FIXTURE_MAILBOX_SECRET")},
      {FixtureApp.Indexer, System.fetch_env!("FIXTURE_ETS_SECRET")},
      FixtureApp.Hoarder,
      FixtureApp.Leaky,
      FixtureApp.Reporter,
      FixtureApp.Backlog,
      {FixtureApp.Pricing, System.fetch_env!("FIXTURE_ARGUMENT_SECRET")},
      FixtureApp.Checkout,
      FixtureApp.Watcher,
      FixtureApp.Awaiter,
      FixtureApp.Parked,
      FixtureApp.Mailroom,
      FixtureApp.Courier,
      FixtureApp.Tail,
      Supervisor.child_spec(FixtureApp.Disguised, type: :supervisor),
      Supervisor.child_spec(FixtureApp.Tenant, id: {:tenant, System.fetch_env!("FIXTURE_CHILD_ID_SECRET")}),
      FixtureApp.Cart,
      FixtureApp.Promotions,
      FixtureApp.Ring.Starter,
      FixtureApp.Payments.Supervisor,
      {DynamicSupervisor, name: FixtureApp.Stuck.Supervisor, strategy: :one_for_one},
      FixtureApp.Stuck.Starter,
      {DynamicSupervisor, name: FixtureApp.Workers, strategy: :one_for_one},
      FixtureApp.Workers.Starter,
      FixtureApp.Ready
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FixtureApp.Supervisor)
  end
end

# Tells the health check the planted faults have had time to form.
defmodule FixtureApp.Ready do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :ready, 1_500)
    {:ok, nil}
  end

  @impl true
  def handle_info(:ready, state) do
    GenServer.call(FixtureApp.Archive, :finished?, :infinity)
    File.write!("/tmp/fixture_app.ready", "")
    {:noreply, state}
  end
end

# Did a lot of work once, right after boot, and has been idle since. Its lifetime
# reductions stay far above the hog's for the life of a case.
defmodule FixtureApp.Archive do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil, {:continue, :import}}

  @impl true
  def handle_continue(:import, state) do
    count(200_000_000)
    {:noreply, state}
  end

  @impl true
  def handle_call(:finished?, _from, state), do: {:reply, true, state}

  defp count(0), do: :ok
  defp count(n), do: count(n - 1)
end

# Unnamed. Burns a steady, modest amount of CPU: the process that is busy now.
defmodule FixtureApp.Hog do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_) do
    send(self(), :work)
    {:ok, nil}
  end

  @impl true
  def handle_info(:work, state) do
    spin(50_000)
    Process.send_after(self(), :work, 10)
    {:noreply, state}
  end

  defp spin(0), do: :ok
  defp spin(n), do: spin(n - 1)
end

# An ordinary named GenServer with no handle_call. Any unexpected call crashes it.
# It counts its own starts, so a case can prove a read did not restart it.
defmodule FixtureApp.Plain do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :persistent_term.put(:fixture_plain_starts, :persistent_term.get(:fixture_plain_starts, 0) + 1)
    {:ok, nil}
  end
end

# Holds a secret in its state and in its process dictionary.
defmodule FixtureApp.Vault do
  use GenServer

  def start_link(secret), do: GenServer.start_link(__MODULE__, secret, name: __MODULE__)

  @impl true
  def init(secret) do
    Process.put(:api_secret, secret)
    {:ok, %{secret: secret}}
  end
end

# Unnamed and stuck, so its mailbox only grows. A process list shows it as
# proc_lib.init_p/5 unless the reader asks what it runs.
defmodule FixtureApp.Inbox do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_) do
    :persistent_term.put(:fixture_inbox, self())
    send(self(), :stick)
    {:ok, nil}
  end

  @impl true
  def handle_info(:stick, state) do
    Process.sleep(:infinity)
    {:noreply, state}
  end
end

# Floods the inbox. Its messages carry a secret, and so do the arguments of a
# function a call trace can name.
defmodule FixtureApp.Sender do
  use GenServer

  def start_link(secret), do: GenServer.start_link(__MODULE__, secret, name: __MODULE__)

  @impl true
  def init(secret) do
    send(self(), :tick)
    {:ok, {secret, 0}}
  end

  @impl true
  def handle_info(:tick, {secret, n}) do
    __MODULE__.deliver(:persistent_term.get(:fixture_inbox, nil), n, secret)
    __MODULE__.stamp(n)
    Process.send_after(self(), :tick, 5)
    {:noreply, {secret, n + 1}}
  end

  def deliver(nil, _n, _secret), do: :ok
  def deliver(inbox, n, secret), do: send(inbox, {:order_event, n, secret})

  # Takes nothing secret, so a trace that prints arguments can show it.
  def stamp(n), do: {:stamped, n}
end

# Grows an ETS table forever. Each row holds a secret.
defmodule FixtureApp.Indexer do
  use GenServer

  def start_link(secret), do: GenServer.start_link(__MODULE__, secret, name: __MODULE__)

  @impl true
  def init(secret) do
    :ets.new(:fixture_search_index, [:named_table, :public])
    send(self(), :tick)
    {:ok, {secret, 0}}
  end

  @impl true
  def handle_info(:tick, {secret, n}) do
    :ets.insert(:fixture_search_index, {n, secret})
    Process.send_after(self(), :tick, 2)
    {:noreply, {secret, n + 1}}
  end
end

# Keeps references to large binaries, so its off-heap memory stands out.
defmodule FixtureApp.Hoarder do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: {:ok, for(n <- 1..40, do: :binary.copy(<<n>>, 200_000))}
end

# Touched many binaries and dropped them, but stays idle, so nothing collects the
# references until something forces a collection.
defmodule FixtureApp.Leaky do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil, {:continue, :touch}}

  @impl true
  def handle_continue(:touch, state) do
    Enum.each(1..200, fn n -> :erlang.phash2(:binary.copy(<<n>>, 1_000)) end)
    {:noreply, state}
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

# Writes to a peer that never reads, on loopback, so bytes queue in the driver.
defmodule FixtureApp.Backlog do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, send_timeout: :infinity])
    {:ok, peer} = :gen_tcp.accept(listener)
    send(self(), :flood)
    {:ok, {listener, client, peer}}
  end

  @impl true
  def handle_info(:flood, {_listener, client, _peer} = state) do
    # Blocks once the kernel buffers and the driver queue are full.
    flood(client, :binary.copy(<<0>>, 1_048_576))
    {:noreply, state}
  end

  defp flood(socket, chunk) do
    :ok = :gen_tcp.send(socket, chunk)
    flood(socket, chunk)
  end
end

# Every call blocks, so callers queue behind it: a bottleneck. The argument of the
# function it blocks in carries a secret, which a stack sample must not print.
defmodule FixtureApp.Pricing do
  use GenServer

  def start_link(secret), do: GenServer.start_link(__MODULE__, secret, name: __MODULE__)
  def quote(), do: GenServer.call(__MODULE__, :quote, :infinity)

  @impl true
  def init(secret), do: {:ok, secret}

  @impl true
  def handle_call(:quote, _from, secret) do
    answer = slow_quote(secret)
    {:reply, answer, secret}
  end

  def slow_quote(secret) do
    Process.sleep(:infinity)
    {:ok, secret}
  end
end

# Five callers stuck behind the bottleneck.
defmodule FixtureApp.Checkout do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    for _ <- 1..5, do: spawn_link(fn -> FixtureApp.Pricing.quote() end)
    {:ok, nil}
  end
end

# Blocked behind the same bottleneck, but it also monitors another process, so its
# monitors alone cannot say which one it waits for.
defmodule FixtureApp.Watcher do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :watch, 200)
    {:ok, nil}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(FixtureApp.Plain)
    FixtureApp.Pricing.quote()
    {:noreply, state}
  end
end

# Waits on a task that never finishes. Task.await has no single monitor to trust.
defmodule FixtureApp.Awaiter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :await)
    {:ok, nil}
  end

  @impl true
  def handle_info(:await, state) do
    Task.await(Task.async(fn -> Process.sleep(:infinity) end), :infinity)
    {:noreply, state}
  end
end

# A large mailbox that stopped growing long ago: the biggest now, not the fastest.
defmodule FixtureApp.Parked do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    for n <- 1..50_000, do: send(self(), {:parked, n})
    {:ok, nil, {:continue, :stick}}
  end

  @impl true
  def handle_continue(:stick, state) do
    Process.sleep(:infinity)
    {:noreply, state}
  end
end

# Stuck and registered, and flooded by name rather than by pid.
defmodule FixtureApp.Mailroom do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil, {:continue, :stick}}

  @impl true
  def handle_continue(:stick, state) do
    Process.sleep(:infinity)
    {:noreply, state}
  end
end

defmodule FixtureApp.Courier do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :tick)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    send(FixtureApp.Mailroom, :parcel)
    Process.send_after(self(), :tick, 10)
    {:noreply, state}
  end
end

# Stuck, with a program writing to it: its mailbox is flooded by a port.
defmodule FixtureApp.Tail do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "while :; do echo line; sleep 0.05; done"]])
    {:ok, nil, {:continue, :stick}}
  end

  @impl true
  def handle_continue(:stick, state) do
    Process.sleep(:infinity)
    {:noreply, state}
  end
end

# An ordinary GenServer under a child spec that calls it a supervisor, which OTP
# accepts. A call it does not expect would crash it.
defmodule FixtureApp.Disguised do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :persistent_term.put(:fixture_disguised_starts, :persistent_term.get(:fixture_disguised_starts, 0) + 1)
    {:ok, nil}
  end
end

# Started under a child id that carries a secret, as a tenant-keyed tree might.
defmodule FixtureApp.Tenant do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_), do: {:ok, nil}
end

# The cart calls promotions, which calls the cart back while handling that call:
# a deadlock, whichever order the two processes run in.
defmodule FixtureApp.Cart do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :call, 500)
    {:ok, nil}
  end

  @impl true
  def handle_info(:call, state) do
    GenServer.call(FixtureApp.Promotions, :rules, :infinity)
    {:noreply, state}
  end

  @impl true
  def handle_call(:lines, _from, state), do: {:reply, [], state}
end

defmodule FixtureApp.Promotions do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call(:rules, _from, state) do
    lines = GenServer.call(FixtureApp.Cart, :lines, :infinity)
    {:reply, lines, state}
  end
end

# A deadlock through 25 processes, each calling the next while handling a call.
defmodule FixtureApp.Ring.Member do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_cast({:next, next}, _state), do: {:noreply, next}

  @impl true
  def handle_info(:pass, next) do
    GenServer.call(next, :pass, :infinity)
    {:noreply, next}
  end

  @impl true
  def handle_call(:pass, _from, next) do
    {:reply, GenServer.call(next, :pass, :infinity), next}
  end
end

defmodule FixtureApp.Ring.Starter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    members = for _ <- 1..25, do: elem(FixtureApp.Ring.Member.start_link(nil), 1)

    members
    |> Enum.zip(tl(members) ++ [hd(members)])
    |> Enum.each(fn {member, next} -> GenServer.cast(member, {:next, next}) end)

    send(hd(members), :pass)
    {:ok, nil}
  end
end

# A child that dies every half second under a supervisor that keeps restarting it.
defmodule FixtureApp.Payments.Gateway do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :die, 500)
    {:ok, nil}
  end

  @impl true
  def handle_info(:die, state), do: {:stop, :gateway_down, state}
end

defmodule FixtureApp.Payments.Supervisor do
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Supervisor.init([FixtureApp.Payments.Gateway], strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1)
  end
end

# A child whose init never returns wedges its DynamicSupervisor in start_child,
# which is how a supervisor stops answering in production.
defmodule FixtureApp.Stuck.Child do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_) do
    Process.sleep(:infinity)
    {:ok, nil}
  end
end

defmodule FixtureApp.Stuck.Starter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    spawn_link(fn -> DynamicSupervisor.start_child(FixtureApp.Stuck.Supervisor, FixtureApp.Stuck.Child) end)
    {:ok, nil}
  end
end

defmodule FixtureApp.Workers.Worker do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_), do: {:ok, nil}
end

# Fills a DynamicSupervisor past any reasonable listing limit. Also starts a
# process that nothing links to or monitors: an orphan inside the application.
defmodule FixtureApp.Workers.Starter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    for _ <- 1..300, do: DynamicSupervisor.start_child(FixtureApp.Workers, FixtureApp.Workers.Worker)

    spawn(fn ->
      Process.register(self(), :fixture_import_watcher)
      Process.sleep(:infinity)
    end)

    {:ok, nil}
  end
end
