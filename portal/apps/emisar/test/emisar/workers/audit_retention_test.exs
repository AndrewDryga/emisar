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
end
