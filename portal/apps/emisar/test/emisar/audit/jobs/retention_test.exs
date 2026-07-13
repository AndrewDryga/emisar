defmodule Emisar.Audit.Jobs.RetentionTest do
  @moduledoc """
  The nightly prune of audit events older than the account plan's
  retention window (free = 7 days).
  """
  use Emisar.DataCase, async: true
  alias Emisar.Audit
  alias Emisar.Audit.Jobs.Retention
  alias Emisar.Fixtures
  alias Emisar.Repo

  test "runs daily because retention horizons have day-level precision" do
    assert %{
             id: Retention,
             start: {_executor, :start_link, [{Retention, interval, _config}]}
           } = Retention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "execute/1 prunes events past the plan window and keeps fresh ones" do
    account = Fixtures.Accounts.create_account()

    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, stale} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    {:ok, fresh} = Audit.log(account.id, "user.signed_in", actor_kind: "user")

    assert :ok = Retention.execute([])

    refute Repo.reload(stale)
    assert Repo.reload(fresh)
  end

  # (plan-window) — the cutoff follows the
  # account's PLAN, not a fixed 7 days: a 10-day-old row survives on Team (90-day
  # retention), whereas the free-plan test above prunes the same-age row. Proves
  # the window is plan-derived (audit_retention_days), not hard-coded.
  test "keeps events within a paid plan's wider retention window" do
    account = Fixtures.Accounts.create_account(plan: "team")
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, within_team_window} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    assert :ok = Retention.execute([])

    # 10 days < the 90-day Team window → kept (the free plan would have pruned it).
    assert Repo.reload(within_team_window)
  end

  # The whole point of per-row `retain_until`: a plan DOWNGRADE must not
  # retroactively wipe history written under the wider window. The sweep prunes by
  # each row's stamped horizon, not by recomputing the cutoff from the (now smaller)
  # current window — so a downgrade only shrinks FUTURE rows.
  test "a downgrade does not retroactively prune rows stamped under a wider window" do
    account = Fixtures.Accounts.create_account()
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    # A 10-day-old row whose horizon is still in the future (as if written under a
    # 90-day window, then the account downgraded to Free's 7 days).
    {:ok, wide} =
      Audit.log(account.id, "user.signed_in",
        actor_kind: "user",
        occurred_at: ten_days_ago,
        retain_until: DateTime.add(DateTime.utc_now(), 80 * 86_400, :second)
      )

    # A same-age row whose stamped horizon has already passed prunes as normal.
    {:ok, expired} =
      Audit.log(account.id, "user.signed_in",
        actor_kind: "user",
        occurred_at: ten_days_ago,
        retain_until: DateTime.add(DateTime.utc_now(), -86_400, :second)
      )

    assert :ok = Retention.execute([])

    # The wide-window row survives the Free-plan sweep (the OLD cutoff-from-current-
    # plan behaviour would have deleted it); the expired one is gone.
    assert Repo.reload(wide)
    refute Repo.reload(expired)
  end

  test "records one audit.retention_swept marker per pruned account (count in payload)" do
    account = Fixtures.Accounts.create_account()
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, _stale} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    assert :ok = Retention.execute([])

    # The stale row is gone; a summary marker for the pruned account remains (and
    # its own retain_until keeps it from being pruned in the same pass).
    assert [swept] =
             Emisar.Audit.Event
             |> Repo.all()
             |> Enum.filter(&(&1.event_type == "audit.retention_swept"))

    assert swept.account_id == account.id
    assert swept.payload["count"] == 1
  end

  test "records no marker when a sweep prunes nothing (no self-spam)" do
    account = Fixtures.Accounts.create_account()
    # A fresh row is within the Free window → nothing to prune, so no marker.
    {:ok, _fresh} = Audit.log(account.id, "user.signed_in", actor_kind: "user")

    assert :ok = Retention.execute([])

    events = Repo.all(Emisar.Audit.Event)
    refute Enum.any?(events, &(&1.event_type == "audit.retention_swept"))
  end

  test "deletes an expired retention marker without replacing it" do
    account = Fixtures.Accounts.create_account()
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, expired_marker} =
      Audit.log(account.id, "audit.retention_swept",
        actor_kind: "system",
        target_kind: "audit_log",
        occurred_at: ten_days_ago,
        payload: %{count: 1}
      )

    assert :ok = Retention.execute([])

    refute Repo.reload(expired_marker)

    # The next scheduled tick remains silent too; the first pass did not seed a
    # replacement marker for the job to perpetuate.
    assert :ok = Retention.execute([])

    refute Emisar.Audit.Event.Query.all()
           |> Emisar.Audit.Event.Query.by_account_id(account.id)
           |> Emisar.Audit.Event.Query.by_event_type("audit.retention_swept")
           |> Repo.exists?()
  end

  test "an expired retention marker does not inflate a meaningful prune count" do
    account = Fixtures.Accounts.create_account()
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, _expired_marker} =
      Audit.log(account.id, "audit.retention_swept",
        actor_kind: "system",
        target_kind: "audit_log",
        occurred_at: ten_days_ago,
        payload: %{count: 9}
      )

    {:ok, _stale_event} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    assert :ok = Retention.execute([])

    assert [replacement] =
             Emisar.Audit.Event
             |> Repo.all()
             |> Enum.filter(&(&1.event_type == "audit.retention_swept"))

    assert replacement.payload["count"] == 1
  end

  # an account whose subscription carries an unknown /
  # renamed plan name resolves to the "free" window rather than crashing, so a
  # legacy plan string can't wedge the nightly prune.
  test "falls back to the free window when the plan is unresolvable" do
    account = Fixtures.Accounts.create_account()
    # A subscription with a plan name no @plans entry matches; Billing.plan/1
    # returns nil for it and the worker falls back to the free (7-day) window.
    Fixtures.Accounts.create_subscription(account, "legacy-unlisted-plan")

    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, stale} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    assert :ok = Retention.execute([])

    # 10 days > the free fallback's 7-day window → pruned.
    refute Repo.reload(stale)
  end

  # the sweep pages accounts via `Account.Query.all`, not
  # `not_deleted()`, on purpose: a soft-deleted (closed) account's old audit rows
  # still occupy space and must age out of its plan window all the same. A
  # regression to `not_deleted()` would strand them forever.
  test "prunes a tombstoned account's events past the window" do
    account = Fixtures.Accounts.create_account()
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, stale} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    # Soft-delete the account (a direct row write — no Subject path deletes an
    # account here, and the fixture way is to build the row state directly).
    account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    assert :ok = Retention.execute([])

    refute Repo.reload(stale)
  end

  test "walks account pages and prunes them all" do
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
    accounts = for _ <- 1..3, do: Fixtures.Accounts.create_account()

    stale =
      for account <- accounts do
        {:ok, event} =
          Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

        event
      end

    # `limit: 1` forces one account per page, so the sweep only completes by
    # walking account-to-account inside the supervised job tick.
    assert :ok = Retention.execute(limit: 1)

    for event <- stale, do: refute(Repo.reload(event))
  end
end
