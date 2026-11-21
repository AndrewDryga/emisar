defmodule Emisar.Catalog.Jobs.PackVersionRetentionTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Billing, Catalog, Fixtures, Repo, Runners}
  alias Emisar.Catalog.Jobs.PackVersionRetention
  alias Emisar.Catalog.PackBaseline

  @beyond_window_days 40
  @window_days 30

  defp stale_pack_version(account) do
    pack_version =
      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: "stale-tools",
        version: "1.0"
      )

    seen_at = DateTime.add(DateTime.utc_now(), -@beyond_window_days * 86_400, :second)
    Fixtures.Catalog.backdate_pack_version_last_seen(pack_version, seen_at)
  end

  # A shipped pack with a retirement watermark; "0.0.0" sits strictly below
  # every one, so the row reads as retired whichever pack sorts first.
  defp retired_pack_version(account) do
    {pack_id, _watermark} = PackBaseline.retired_below() |> Enum.sort() |> List.first()

    Fixtures.Catalog.create_trusted_pack_version(
      account_id: account.id,
      pack_id: pack_id,
      version: "0.0.0"
    )
  end

  defp deleted_runner_action(account, days_ago) do
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    action = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
    deleted_at = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    Fixtures.Runners.mark_deleted(runner, deleted_at)
    action
  end

  defp markers(account_id, event_type) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type(event_type)
    |> Repo.all()
  end

  defp retention_markers(account_id), do: markers(account_id, "pack_retention_swept")
  defp retirement_markers(account_id), do: markers(account_id, "pack_retirement_swept")

  test "runs daily because the retention promise has day-level precision" do
    assert %{
             id: PackVersionRetention,
             start: {_executor, :start_link, [{PackVersionRetention, interval, _config}]}
           } = PackVersionRetention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "prunes versions unseen past a subscribed account's window (idempotently)" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_pack_retention_days(account, @window_days)
    stale = stale_pack_version(account)

    assert PackVersionRetention.execute([]) == :ok
    assert PackVersionRetention.execute([]) == :ok

    refute Repo.reload(stale)
    assert length(retention_markers(account.id)) == 1
  end

  test "keeps versions seen within the window" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_pack_retention_days(account, @window_days)

    kept =
      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: "fresh-tools",
        version: "2.0"
      )

    assert PackVersionRetention.execute([]) == :ok

    assert Repo.reload(kept)
  end

  test "skips accounts without the retention setting" do
    account = Fixtures.Accounts.create_account()
    stale = stale_pack_version(account)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert PackVersionRetention.execute([]) == :ok
      end)

    assert Repo.reload(stale)
    assert retention_markers(account.id) == []
    # Cleanup being off is the normal answer, not a sweep failure.
    refute log =~ "pack_version_retention.failed"
  end

  test "leaves no housekeeping marker for an account with nothing to remove" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_pack_retention_days(account, @window_days)

    assert PackVersionRetention.execute([]) == :ok
    assert PackVersionRetention.execute([]) == :ok

    assert retention_markers(account.id) == []
  end

  test "the swept version's dispatch pin is gone (fails closed as untrusted)" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_pack_retention_days(account, @window_days)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    stale = stale_pack_version(account)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "stale.check",
        pack_id: stale.pack_id,
        pack_version: stale.version
      )

    assert PackVersionRetention.execute([]) == :ok

    assert Catalog.check_pack_trusted(action) == {:error, :pack_untrusted, :no_pin}
  end

  test "bounded candidate batches audit and continue across account pages" do
    accounts = for _ <- 1..2, do: Fixtures.Accounts.create_account()

    for account <- accounts do
      Fixtures.Accounts.set_pack_retention_days(account, @window_days)

      for index <- 1..3 do
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: "stale#{index}",
          version: "1.0"
        )
        |> Fixtures.Catalog.backdate_pack_version_last_seen(
          DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
        )
      end
    end

    assert PackVersionRetention.execute(limit: 1, batch_size: 2) == :ok
    assert PackVersionRetention.execute(limit: 1, batch_size: 2) == :ok

    for account <- accounts do
      counts = account.id |> retention_markers() |> Enum.map(& &1.payload["count"]) |> Enum.sort()
      assert counts == [1, 2]
    end
  end

  describe "retired versions" do
    test "removes a retired version no runner advertises, even with automatic cleanup off" do
      account = Fixtures.Accounts.create_account()
      retired = retired_pack_version(account)

      assert PackVersionRetention.execute([]) == :ok
      assert PackVersionRetention.execute([]) == :ok

      refute Repo.reload(retired)
      assert [marker] = retirement_markers(account.id)
      assert marker.actor_kind == "system"
      assert marker.payload["count"] == 1
      assert marker.payload["versions"] == ["#{retired.pack_id}@0.0.0"]
    end

    test "keeps a retired version an offline runner still lists" do
      # Offline is not gone: the host re-advertises what it has installed on
      # reconnect, so the sweep reads the durable packs map of every runner
      # that is not deleted — the set the console's "no runner is on it" counts.
      account = Fixtures.Accounts.create_account()
      retired = retired_pack_version(account)
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.advertise_packs(runner, %{retired.pack_id => %{"version" => "0.0.0"}})

      assert PackVersionRetention.execute([]) == :ok

      assert Repo.reload(retired)
      assert retirement_markers(account.id) == []
    end

    test "another account's advertiser does not shield a retired version" do
      account = Fixtures.Accounts.create_account()
      retired = retired_pack_version(account)
      other = Fixtures.Runners.create_runner()
      Fixtures.Runners.advertise_packs(other, %{retired.pack_id => %{"version" => "0.0.0"}})

      assert PackVersionRetention.execute([]) == :ok

      refute Repo.reload(retired)
    end

    test "keeps a shipped version at its pack's watermark" do
      account = Fixtures.Accounts.create_account()
      {pack_id, watermark} = PackBaseline.retired_below() |> Enum.sort() |> List.first()

      current =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: watermark
        )

      assert PackVersionRetention.execute([]) == :ok

      assert Repo.reload(current)
      assert retirement_markers(account.id) == []
    end

    test "the removed version's dispatch pin and action rows are gone" do
      account = Fixtures.Accounts.create_account()
      retired = retired_pack_version(account)
      # An action row alone is not an advertisement — the runner's durable
      # packs map is — so a host that no longer lists the pack does not shield
      # the rows it once advertised.
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      action =
        Fixtures.Catalog.create_action(
          runner: runner,
          action_id: "retired.check",
          pack_id: retired.pack_id,
          pack_version: retired.version
        )

      assert PackVersionRetention.execute([]) == :ok

      refute Repo.reload(action)
      assert Catalog.check_pack_trusted(action) == {:error, :pack_untrusted, :no_pin}
    end
  end

  describe "deleted runners' catalog rows" do
    test "prunes the rows of a runner deleted past audit retention, with cleanup off" do
      account = Fixtures.Accounts.create_account()
      assert Runners.inactive_retention_hours(account) == {:error, :retention_disabled}
      assert Catalog.pack_retention_days(account) == {:error, :retention_disabled}
      days = Billing.account_audit_retention_days(account.id)
      long_deleted = deleted_runner_action(account, days + 1)
      recently_deleted = deleted_runner_action(account, days - 1)
      live = Fixtures.Runners.create_runner(account_id: account.id)
      live_action = Fixtures.Catalog.create_action(runner: live, action_id: "linux.uptime")

      assert PackVersionRetention.execute([]) == :ok

      refute Repo.reload(long_deleted)
      assert Repo.reload(recently_deleted)
      assert Repo.reload(live_action)
    end

    test "leaves another account's rows and is a no-op the second time, in bounded batches" do
      account = Fixtures.Accounts.create_account()
      other = Fixtures.Accounts.create_account(plan: "team")
      days = Billing.account_audit_retention_days(account.id)
      assert Billing.account_audit_retention_days(other.id) > days + 1

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      pruned =
        for action_id <- ~w(linux.uptime linux.df linux.free),
            do: Fixtures.Catalog.create_action(runner: runner, action_id: action_id)

      Fixtures.Runners.mark_deleted(
        runner,
        DateTime.add(DateTime.utc_now(), -(days + 1) * 86_400, :second)
      )

      foreign = deleted_runner_action(other, days + 1)

      assert PackVersionRetention.execute(batch_size: 2) == :ok
      after_first = Repo.all(Catalog.RunnerAction)
      assert PackVersionRetention.execute(batch_size: 2) == :ok

      assert Enum.all?(pruned, &is_nil(Repo.reload(&1)))
      assert Repo.reload(foreign)
      assert Repo.all(Catalog.RunnerAction) == after_first
    end
  end
end
