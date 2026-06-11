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
end
