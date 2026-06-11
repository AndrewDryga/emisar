defmodule Emisar.Workers.BillingSyncTest do
  @moduledoc """
  The hourly Paddle reconciliation: every mirrored subscription is
  re-fetched from the vendor (the stub here) so a missed webhook can't
  leave an account on stale entitlements.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Billing, Repo}
  alias Emisar.Billing.Subscription
  alias Emisar.Workers.BillingSync

  test "perform/1 refreshes status + period end from the vendor" do
    account = account_fixture()

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_sync_1",
        plan: "team",
        status: "past_due",
        current_period_end: nil
      })

    assert :ok = BillingSync.perform(%Oban.Job{args: %{}})

    synced = Repo.reload!(subscription)
    # The stub reports every subscription as active with a fresh period.
    assert synced.status == "active"
    assert %DateTime{} = synced.current_period_end
  end

  test "perform/1 skips a mirror row with no vendor subscription id" do
    account = account_fixture()

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{plan: "free", status: "none"})

    assert :ok = BillingSync.perform(%Oban.Job{args: %{}})

    assert %Subscription{status: "none"} = Repo.reload!(subscription)
  end
end
