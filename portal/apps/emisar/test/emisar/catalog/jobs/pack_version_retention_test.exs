defmodule Emisar.Catalog.Jobs.PackVersionRetentionTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Catalog, Fixtures, Repo}
  alias Emisar.Catalog.Jobs.PackVersionRetention

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

  defp retention_markers(account_id) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type("pack_retention_swept")
    |> Repo.all()
  end

  test "runs daily because the retention promise has day-level precision" do
    assert %{
             id: PackVersionRetention,
             start: {_executor, :start_link, [{PackVersionRetention, interval, _config}]}
           } = PackVersionRetention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "prunes versions unseen past a subscribed account's window (idempotently)" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: @window_days})
    stale = stale_pack_version(account)

    assert :ok = PackVersionRetention.execute([])
    assert :ok = PackVersionRetention.execute([])

    refute Repo.reload(stale)
    assert length(retention_markers(account.id)) == 1
  end

  test "keeps versions seen within the window" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: @window_days})

    kept =
      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: "fresh-tools",
        version: "2.0"
      )

    assert :ok = PackVersionRetention.execute([])

    assert Repo.reload(kept)
  end

  test "skips accounts without the retention setting" do
    account = Fixtures.Accounts.create_account()
    stale = stale_pack_version(account)

    assert :ok = PackVersionRetention.execute([])

    assert Repo.reload(stale)
    assert retention_markers(account.id) == []
  end

  test "leaves no housekeeping marker for an account with nothing to remove" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: @window_days})

    assert :ok = PackVersionRetention.execute([])
    assert :ok = PackVersionRetention.execute([])

    assert retention_markers(account.id) == []
  end

  test "the swept version's dispatch pin is gone (fails closed as untrusted)" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: @window_days})
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    stale = stale_pack_version(account)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "stale.check",
        pack_id: stale.pack_id,
        pack_version: stale.version
      )

    assert :ok = PackVersionRetention.execute([])

    assert {:error, :pack_untrusted, :no_pin} = Catalog.check_pack_trusted(action)
  end
end
