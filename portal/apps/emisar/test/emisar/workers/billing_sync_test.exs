# A Paddle client whose retrieve fails for one specific subscription id and
# succeeds (active, fresh period) for the rest — lets the sweep's
# one-bad-row-doesn't-abort-the-batch behaviour be exercised deterministically.
# The failing id is read from app env so the module stays stateless.
defmodule Emisar.Workers.BillingSyncTest.PartialFailPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def retrieve_subscription(id) do
    if id == Application.get_env(:emisar, :billing_sync_test_fail_id) do
      {:error, :paddle_unavailable}
    else
      {:ok,
       %{
         "id" => id,
         "status" => "active",
         "next_billed_at" =>
           DateTime.utc_now() |> DateTime.add(30 * 86_400, :second) |> DateTime.to_iso8601()
       }}
    end
  end

  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.Workers.BillingSyncTest do
  @moduledoc """
  The hourly Paddle reconciliation: every mirrored subscription is
  re-fetched from the vendor (the stub here) so a missed webhook can't
  leave an account on stale entitlements.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Billing, Repo}
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Workers.BillingSync
  alias Emisar.Workers.BillingSyncTest.PartialFailPaddleClient

  setup do
    %{account: Fixtures.Accounts.create_account()}
  end

  test "perform/1 refreshes status + period end from the vendor", %{account: account} do
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

  test "perform/1 skips a mirror row with no vendor subscription id", %{account: account} do
    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{plan: "free", status: "none"})

    assert :ok = BillingSync.perform(%Oban.Job{args: %{}})

    assert %Subscription{status: "none"} = Repo.reload!(subscription)
  end

  test "perform/1 reads string-key vendor payload (IL-13 round-trip safe)", %{account: account} do
    # The stub returns a map with STRING keys ("status"/"next_billed_at"), as a
    # JSON-decoded Paddle payload would; the worker reads them by string key, so
    # there's no atom-key crash on the round-tripped vendor data.
    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_strkey_1",
        plan: "team",
        status: "past_due",
        current_period_end: nil
      })

    assert :ok = BillingSync.perform(%Oban.Job{args: %{}})

    synced = Repo.reload!(subscription)
    assert synced.status == "active"
    assert %DateTime{} = synced.current_period_end
  end

  test "perform/1 accepts string-key Oban args without crashing (IL-13)", %{account: account} do
    # (the args half)
    # The scheduled job round-trips its args through the DB as string keys; the
    # worker ignores them but must not pattern-match atom keys. A bare %{} and a
    # string-keyed map both drive a clean sweep.
    {:ok, _} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_strkey_args_1",
        plan: "team",
        status: "active"
      })

    assert :ok = BillingSync.perform(%Oban.Job{args: %{"scheduled" => true}})
  end

  test "perform/1 runs Subject-less — it's a trusted server sweep, not a per-account read",
       %{account: account} do
    # The hourly reconciliation operates on already-trusted server context: it
    # reconciles every mirror row against the vendor with no per-account authz, so
    # its contract is the Oban arity-1 perform/1 — no %Subject{} anywhere on the
    # path. (Confirms the documented internal-sweep posture.)
    #
    # function_exported?/3 reports false for a module that isn't loaded yet, which
    # the async suite doesn't guarantee — force the load so the arity probe is
    # deterministic rather than racing first-touch.
    assert Code.ensure_loaded?(BillingSync)
    assert function_exported?(BillingSync, :perform, 1)
    refute function_exported?(BillingSync, :perform, 2)

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_nosubj_sweep",
        plan: "team",
        status: "past_due"
      })

    assert :ok = BillingSync.perform(%Oban.Job{args: %{}})
    assert %Subscription{status: "active"} = Repo.reload!(subscription)
  end
end

defmodule Emisar.Workers.BillingSyncVendorFailTest do
  @moduledoc """
  The sweep's one-bad-row-doesn't-abort-the-batch behaviour. Swaps
  `:paddle_client` (process-global) to a client that fails one specific
  subscription id, so this module is `async: false` — a concurrent async test
  calling the Paddle client must not observe the failing client mid-run.
  """
  use Emisar.DataCase, async: false
  alias Emisar.{Billing, Repo}
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Workers.BillingSync
  alias Emisar.Workers.BillingSyncTest.PartialFailPaddleClient

  setup do
    prev_client = Application.get_env(:emisar, :paddle_client)
    Application.put_env(:emisar, :paddle_client, PartialFailPaddleClient)

    on_exit(fn ->
      case prev_client do
        nil -> Application.delete_env(:emisar, :paddle_client)
        value -> Application.put_env(:emisar, :paddle_client, value)
      end

      Application.delete_env(:emisar, :billing_sync_test_fail_id)
    end)

    :ok
  end

  @tag capture_log: true
  test "a single retrieve failure is logged and the sweep continues to the next row" do
    # The first subscription's retrieve errors (logged with both ids, → Sentry);
    # the sweep does NOT abort — the second subscription is still refreshed from
    # the vendor. perform/1 returns :ok regardless of the per-row failure.
    import ExUnit.CaptureLog

    failing_account = Fixtures.Accounts.create_account()

    {:ok, failing} =
      Billing.upsert_subscription(failing_account.id, %{
        paddle_subscription_id: "sub_fail_row",
        plan: "team",
        status: "past_due",
        current_period_end: nil
      })

    Application.put_env(:emisar, :billing_sync_test_fail_id, "sub_fail_row")

    ok_account = Fixtures.Accounts.create_account()

    {:ok, ok_row} =
      Billing.upsert_subscription(ok_account.id, %{
        paddle_subscription_id: "sub_ok_row",
        plan: "team",
        status: "past_due",
        current_period_end: nil
      })

    log =
      capture_log(fn ->
        assert :ok = BillingSync.perform(%Oban.Job{args: %{}})
      end)

    # The failure surfaced (both ids logged for the operator / Sentry)…
    assert log =~ "billing_sync.retrieve_failed"
    assert log =~ "sub_fail_row"

    # …the failing row was left untouched (still past_due, no fresh period)…
    assert %Subscription{status: "past_due", current_period_end: nil} = Repo.reload!(failing)

    # …and the good row was still reconciled — the sweep did not abort early.
    assert %Subscription{status: "active"} = Repo.reload!(ok_row)
  end
end

# A Paddle client that reports a status string this code has never modeled, so
# the sweep's upsert of a vendor-owned status value can be exercised.
defmodule Emisar.Workers.BillingSyncUnknownStatusTest.UnknownStatusPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def retrieve_subscription(id),
    do: {:ok, %{"id" => id, "status" => "some_new_paddle_status"}}

  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.Workers.BillingSyncUnknownStatusTest do
  @moduledoc """
  The sweep persists whatever status Paddle reports. `Subscription.status` is
  deliberately an open `:string` (vendor-owned value space), so a status this
  code has never seen must round-trip into the mirror row rather than failing
  the changeset and 500-ing the sweep. `async: false` — swaps the process-global
  `:paddle_client`.
  """
  use Emisar.DataCase, async: false
  alias Emisar.{Billing, Repo}
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Workers.BillingSync
  alias Emisar.Workers.BillingSyncUnknownStatusTest.UnknownStatusPaddleClient

  setup do
    prev_client = Application.get_env(:emisar, :paddle_client)
    Application.put_env(:emisar, :paddle_client, UnknownStatusPaddleClient)

    on_exit(fn ->
      case prev_client do
        nil -> Application.delete_env(:emisar, :paddle_client)
        value -> Application.put_env(:emisar, :paddle_client, value)
      end
    end)

    :ok
  end

  # an unrecognized Paddle status string persists rather
  # than 500-ing the sweep (no inclusion list on the open `:string` column), so a
  # vendor that mints a new status can't wedge the hourly reconciliation.
  test "perform/1 persists an unrecognized vendor status without crashing" do
    account = Fixtures.Accounts.create_account()

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_unknown_status",
        plan: "team",
        status: "active"
      })

    assert :ok = BillingSync.perform(%Oban.Job{args: %{}})

    assert %Subscription{status: "some_new_paddle_status"} = Repo.reload!(subscription)
  end
end

# A Paddle client that reports a subscription with NO next-billed date (a
# non-renewing / canceled sub), so the sweep's preserve-stored-period behaviour
# can be exercised.
defmodule Emisar.Workers.BillingSyncNoPeriodTest.NoPeriodPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def retrieve_subscription(id), do: {:ok, %{"id" => id, "status" => "active"}}
  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.Workers.BillingSyncNoPeriodTest do
  @moduledoc """
  When Paddle reports a subscription with no next-billed date (a non-renewing /
  canceled sub), the sweep must NOT NULL the stored current_period_end — a paying
  account mid-cancel keeps its "access until" date. `async: false` — swaps the
  process-global `:paddle_client`.
  """
  use Emisar.DataCase, async: false
  alias Emisar.{Billing, Repo}
  alias Emisar.Fixtures
  alias Emisar.Workers.BillingSync
  alias Emisar.Workers.BillingSyncNoPeriodTest.NoPeriodPaddleClient

  setup do
    prev_client = Application.get_env(:emisar, :paddle_client)
    Application.put_env(:emisar, :paddle_client, NoPeriodPaddleClient)

    on_exit(fn ->
      case prev_client do
        nil -> Application.delete_env(:emisar, :paddle_client)
        value -> Application.put_env(:emisar, :paddle_client, value)
      end
    end)

    :ok
  end

  test "perform/1 preserves a stored current_period_end when Paddle reports no next-billed date" do
    account = Fixtures.Accounts.create_account()
    stored = ~U[2026-09-01 00:00:00.000000Z]

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_no_period",
        plan: "team",
        status: "active",
        current_period_end: stored
      })

    assert :ok = BillingSync.perform(%Oban.Job{args: %{}})

    synced = Repo.reload!(subscription)
    assert synced.status == "active"
    # The hourly tick must NOT clobber the access-until date to nil.
    assert synced.current_period_end == stored
  end
end
