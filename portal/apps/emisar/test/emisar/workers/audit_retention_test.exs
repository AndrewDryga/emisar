defmodule Emisar.Workers.AuditRetentionTest do
  @moduledoc """
  The nightly prune of audit events older than the account plan's
  retention window (free = 7 days).
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Audit, Repo}
  alias Emisar.Workers.AuditRetention

  test "perform/1 prunes events past the plan window and keeps fresh ones" do
    account = account_fixture()

    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, stale} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    {:ok, fresh} = Audit.log(account.id, "user.signed_in", actor_kind: "user")

    assert :ok = AuditRetention.perform(%Oban.Job{args: %{}})

    refute Repo.reload(stale)
    assert Repo.reload(fresh)
  end

  # closes ENG-024-T01, BILL-006-T02 (plan-window) — the cutoff follows the
  # account's PLAN, not a fixed 7 days: a 10-day-old row survives on Team (90-day
  # retention), whereas the free-plan test above prunes the same-age row. Proves
  # the window is plan-derived (audit_retention_days), not hard-coded.
  test "keeps events within a paid plan's wider retention window" do
    account = account_fixture(plan: "team")
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, within_team_window} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    assert :ok = AuditRetention.perform(%Oban.Job{args: %{}})

    # 10 days < the 90-day Team window → kept (the free plan would have pruned it).
    assert Repo.reload(within_team_window)
  end

  # closes ENG-024-T05 — an account whose subscription carries an unknown /
  # renamed plan name resolves to the "free" window rather than crashing, so a
  # legacy plan string can't wedge the nightly prune.
  test "falls back to the free window when the plan is unresolvable" do
    account = account_fixture()
    # A subscription with a plan name no @plans entry matches; Billing.plan/1
    # returns nil for it and the worker falls back to the free (7-day) window.
    subscription_fixture(account, "legacy-unlisted-plan")

    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, stale} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    assert :ok = AuditRetention.perform(%Oban.Job{args: %{}})

    # 10 days > the free fallback's 7-day window → pruned.
    refute Repo.reload(stale)
  end

  # closes ENG-024-T04 — the sweep pages accounts via `Account.Query.all()`, not
  # `not_deleted()`, on purpose: a soft-deleted (closed) account's old audit rows
  # still occupy space and must age out of its plan window all the same. A
  # regression to `not_deleted()` would strand them forever.
  test "prunes a tombstoned account's events past the window" do
    account = account_fixture()
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    {:ok, stale} =
      Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

    # Soft-delete the account (a direct row write — no Subject path deletes an
    # account here, and the fixture way is to build the row state directly).
    account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    assert :ok = AuditRetention.perform(%Oban.Job{args: %{}})

    refute Repo.reload(stale)
  end

  test "pages accounts via a continuation cursor and prunes them all" do
    ten_days_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
    accounts = for _ <- 1..3, do: account_fixture()

    stale =
      for account <- accounts do
        {:ok, event} =
          Audit.log(account.id, "user.signed_in", actor_kind: "user", occurred_at: ten_days_ago)

        event
      end

    # `limit: 1` forces one account per page, so the run only completes by
    # following its own continuation cursor account-to-account (inline test mode
    # runs each enqueued follow-up synchronously). All three must be pruned.
    assert :ok = AuditRetention.perform(%Oban.Job{args: %{"limit" => 1}})

    for event <- stale, do: refute(Repo.reload(event))
  end

  # closes ENG-024-T03 — `maybe_continue` enqueues a cursor follow-up ONLY when a
  # page comes back FULL (more accounts may be behind it). A short page means the
  # account set is drained, so NO follow-up is enqueued. Run under `:manual`
  # testing mode (instead of the suite's `:inline`) so a follow-up `Oban.insert`
  # is persisted and observable via `all_enqueued`, rather than executed inline.
  test "a short page enqueues no follow-up cursor job; a full page does" do
    # Two accounts in the DB.
    _accounts = for _ <- 1..2, do: account_fixture()

    Oban.Testing.with_testing_mode(:manual, fn ->
      # limit: 5 > 2 accounts → short page → drained → no continuation.
      assert :ok = AuditRetention.perform(%Oban.Job{args: %{"limit" => 5}})
      assert Oban.Testing.all_enqueued(repo: Repo, worker: AuditRetention) == []

      # limit: 2 == 2 accounts → full page → a cursor follow-up IS enqueued
      # (proves the assertion above has teeth — the absence is real).
      assert :ok = AuditRetention.perform(%Oban.Job{args: %{"limit" => 2}})
      assert [follow_up] = Oban.Testing.all_enqueued(repo: Repo, worker: AuditRetention)
      assert Map.has_key?(follow_up.args, "after_account_id")
    end)
  end
end
