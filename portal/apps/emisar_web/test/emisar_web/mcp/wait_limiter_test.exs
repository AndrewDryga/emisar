defmodule EmisarWeb.MCP.WaitLimiterTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias EmisarWeb.MCP.WaitLimiter

  test "one credential lineage holds at most eight concurrent waits" do
    conn = conn(System.unique_integer([:positive]))
    waits = hold_waits(conn, 8)

    assert WaitLimiter.run(conn, fn -> flunk("saturated wait ran") end) ==
             {:error, :wait_saturated}

    release_waits(waits)

    assert WaitLimiter.run(conn, fn -> :available end) == :available
  end

  test "different credential lineages do not share capacity" do
    waits = hold_waits(conn(1, "account"), 8)
    assert WaitLimiter.run(conn(2, "account"), fn -> :available end) == :available
    release_waits(waits)
  end

  test "caller crashes return their leases" do
    lineage = System.unique_integer([:positive])
    parent = self()

    for _index <- 1..8 do
      {pid, monitor} =
        spawn_monitor(fn ->
          WaitLimiter.run(conn(lineage), fn ->
            send(parent, :wait_acquired)

            receive do
              :finish -> :ok
            end
          end)
        end)

      assert_receive :wait_acquired, 500
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 500
    end

    assert_eventually_available(conn(lineage), 20)
  end

  defp conn(lineage, account \\ nil) do
    Plug.Test.conn(:get, "/")
    |> assign(:api_key, %{id: "key-#{lineage}", credential_lineage_id: "lineage-#{lineage}"})
    |> assign(:current_subject, %{account: %{id: account || "account-#{lineage}"}})
  end

  defp hold_waits(conn, count) do
    parent = self()

    waits =
      Enum.map(1..count, fn _index ->
        Task.async(fn ->
          WaitLimiter.run(conn, fn ->
            send(parent, {:wait_acquired, self()})

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    Enum.each(waits, fn _task -> assert_receive {:wait_acquired, _pid}, 500 end)
    waits
  end

  defp release_waits(waits) do
    Enum.each(waits, &send(&1.pid, :release))
    assert Enum.map(waits, &Task.await(&1, 500)) == List.duplicate(:ok, length(waits))
  end

  defp assert_eventually_available(_conn, 0), do: flunk("crashed waits leaked capacity")

  defp assert_eventually_available(conn, attempts) do
    case WaitLimiter.run(conn, fn -> :available end) do
      :available ->
        :ok

      {:error, :wait_saturated} ->
        tick = make_ref()
        Process.send_after(self(), {:lease_cleanup_tick, tick}, 5)
        assert_receive {:lease_cleanup_tick, ^tick}, 50
        assert_eventually_available(conn, attempts - 1)
    end
  end
end
