defmodule EmisarWeb.AuditDownloadLimiterTest do
  use ExUnit.Case, async: false
  alias EmisarWeb.AuditDownloadLimiter

  test "allows one preparation per account and at most two per node" do
    account_a = Ecto.UUID.generate()
    account_b = Ecto.UUID.generate()
    account_c = Ecto.UUID.generate()
    preparations = hold_preparations([account_a, account_b])

    assert AuditDownloadLimiter.run(account_a, fn -> flunk("same-account request ran") end) ==
             {:error, :audit_download_saturated}

    assert AuditDownloadLimiter.run(account_c, fn -> flunk("third node request ran") end) ==
             {:error, :audit_download_saturated}

    release_preparations(preparations)
    assert AuditDownloadLimiter.run(account_c, fn -> :available end) == :available
  end

  test "a crashed request returns its lease" do
    account_id = Ecto.UUID.generate()
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        AuditDownloadLimiter.run(account_id, fn ->
          send(parent, :audit_download_acquired)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :audit_download_acquired, 500
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 500
    assert_eventually_available(account_id, 20)
  end

  defp hold_preparations(account_ids) do
    parent = self()

    preparations = Enum.map(account_ids, &hold_preparation(&1, parent))

    Enum.each(preparations, fn _task ->
      assert_receive {:audit_download_acquired, _pid}, 500
    end)

    preparations
  end

  defp hold_preparation(account_id, parent) do
    Task.async(fn ->
      AuditDownloadLimiter.run(account_id, fn ->
        send(parent, {:audit_download_acquired, self()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp release_preparations(preparations) do
    Enum.each(preparations, &send(&1.pid, :release))
    assert Enum.map(preparations, &Task.await(&1, 500)) == [:ok, :ok]
  end

  defp assert_eventually_available(_account_id, 0), do: flunk("crashed request leaked capacity")

  defp assert_eventually_available(account_id, attempts) do
    case AuditDownloadLimiter.run(account_id, fn -> :available end) do
      :available ->
        :ok

      {:error, :audit_download_saturated} ->
        tick = make_ref()
        Process.send_after(self(), {:lease_cleanup_tick, tick}, 5)
        assert_receive {:lease_cleanup_tick, ^tick}, 50
        assert_eventually_available(account_id, attempts - 1)
    end
  end
end
