defmodule Emisar.SSO.OIDC.Guard.RelayTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Emisar.SSO.OIDC.Guard.Relay

  @wait 2_000

  test "relays ordinary bytes in both directions" do
    relay = start_relay(64, 1_000)

    :ok = :gen_tcp.send(relay.client_peer, "hello")
    assert recv_bytes(relay.origin_peer, 5) == "hello"

    :ok = :gen_tcp.send(relay.origin_peer, "back")
    assert recv_bytes(relay.client_peer, 4) == "back"

    :gen_tcp.close(relay.client_peer)
    assert Task.await(relay.task, @wait) == :ok
  end

  test "the byte budget is inclusive and combined across both directions" do
    log =
      capture_log(fn ->
        relay = start_relay(9, 1_000)

        :ok = :gen_tcp.send(relay.client_peer, "12345")
        assert recv_bytes(relay.origin_peer, 5) == "12345"

        :ok = :gen_tcp.send(relay.origin_peer, "6789")
        assert recv_bytes(relay.client_peer, 4) == "6789"

        :ok = :gen_tcp.send(relay.client_peer, "PAYLOAD_SENTINEL")
        assert :gen_tcp.recv(relay.origin_peer, 0, @wait) == {:error, :closed}

        assert Task.await(relay.task, @wait) ==
                 {:error, :tunnel_byte_budget_exceeded}
      end)

    assert log =~ "OIDC guard closed an oversized tunnel"
    refute log =~ "PAYLOAD_SENTINEL"
  end

  test "continuous traffic cannot extend the absolute deadline" do
    log =
      capture_log(fn ->
        relay = start_relay(10_000_000, 150)

        assert stream_until_closed(relay.client_peer, relay.origin_peer, 0) > 1

        assert Task.await(relay.task, @wait) ==
                 {:error, :tunnel_lifetime_exceeded}
      end)

    assert log =~ "OIDC guard closed a tunnel at its lifetime"
  end

  test "one oversized relay closes without disrupting another relay" do
    _log =
      capture_log(fn ->
        oversized = start_relay(1, 1_000)
        healthy = start_relay(64, 1_000)

        :ok = :gen_tcp.send(oversized.client_peer, "too large")
        assert :gen_tcp.recv(oversized.origin_peer, 0, @wait) == {:error, :closed}

        :ok = :gen_tcp.send(healthy.client_peer, "healthy")
        assert recv_bytes(healthy.origin_peer, 7) == "healthy"
        assert Task.await(oversized.task, @wait) == {:error, :tunnel_byte_budget_exceeded}

        :gen_tcp.close(healthy.client_peer)
        assert Task.await(healthy.task, @wait) == :ok
      end)
  end

  test "a destination that stops reading cannot hold the relay past its deadline" do
    _log =
      capture_log(fn ->
        relay =
          start_relay(8_000_000, 250,
            origin_socket_opts: [sndbuf: 1_024],
            origin_peer_opts: [recbuf: 1_024]
          )

        sender =
          Task.async(fn ->
            :gen_tcp.send(relay.client_peer, :binary.copy(<<0>>, 4_000_000))
          end)

        on_exit(fn -> stop_process(sender.pid) end)

        assert {:ok, {:error, reason}} = Task.yield(relay.task, @wait)
        assert reason in [:timeout, :closed, :tunnel_lifetime_exceeded]
        refute Process.alive?(relay.task.pid)

        assert {:ok, sender_result} = Task.yield(sender, @wait)
        assert sender_result in [:ok, {:error, :closed}]
      end)
  end

  defp start_relay(max_bytes, lifetime_ms, opts \\ []) do
    {client_peer, relay_client} = socket_pair()
    {origin_peer, relay_origin} = socket_pair()

    :ok = :inet.setopts(relay_origin, Keyword.get(opts, :origin_socket_opts, []))
    :ok = :inet.setopts(origin_peer, Keyword.get(opts, :origin_peer_opts, []))

    task =
      Task.async(fn ->
        receive do
          {:relay, client, origin, deadline} -> Relay.run(client, origin, deadline, max_bytes)
        end
      end)

    :ok = :gen_tcp.controlling_process(relay_client, task.pid)
    :ok = :gen_tcp.controlling_process(relay_origin, task.pid)

    send(
      task.pid,
      {:relay, relay_client, relay_origin, System.monotonic_time(:millisecond) + lifetime_ms}
    )

    on_exit(fn ->
      :gen_tcp.close(client_peer)
      :gen_tcp.close(origin_peer)
      stop_process(task.pid)
    end)

    %{client_peer: client_peer, origin_peer: origin_peer, task: task}
  end

  defp socket_pair do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()
    ref = make_ref()

    acceptor =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.controlling_process(socket, parent)
        send(parent, {:accepted, ref, socket})
      end)

    {:ok, peer} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], @wait)

    relay_socket =
      receive do
        {:accepted, ^ref, socket} -> socket
      after
        @wait -> flunk("socket pair was not accepted")
      end

    _ = Task.await(acceptor, @wait)
    :gen_tcp.close(listener)
    {peer, relay_socket}
  end

  defp recv_bytes(socket, wanted, acc \\ "") do
    if byte_size(acc) == wanted do
      acc
    else
      assert {:ok, data} = :gen_tcp.recv(socket, wanted - byte_size(acc), @wait)
      recv_bytes(socket, wanted, acc <> data)
    end
  end

  defp stream_until_closed(source, destination, count) do
    case :gen_tcp.send(source, <<0>>) do
      :ok ->
        case :gen_tcp.recv(destination, 1, @wait) do
          {:ok, <<0>>} -> stream_until_closed(source, destination, count + 1)
          {:error, :closed} -> count
        end

      {:error, :closed} ->
        count
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        @wait -> :ok
      end
    end
  end
end
