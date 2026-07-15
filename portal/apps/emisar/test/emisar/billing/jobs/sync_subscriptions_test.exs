# A Paddle client whose retrieve fails for one specific subscription id and
# succeeds (active, fresh period) for the rest — lets the sweep's
# one-bad-row-doesn't-abort-the-batch behaviour be exercised deterministically.
# The failing id is read from app env so the module stays stateless.
defmodule Emisar.Billing.Jobs.SyncSubscriptionsTest.PartialFailPaddleClient do
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
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def list_products, do: {:error, :unused}
  @impl true
  def list_transactions(_attrs), do: {:error, :unused}
  @impl true
  def get_transaction_invoice(_id), do: {:error, :unused}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.Billing.Jobs.SyncSubscriptionsTest do
  @moduledoc """
  The hourly Paddle reconciliation: every mirrored subscription is
  re-fetched from the vendor (the stub here) so a missed webhook can't
  leave an account on stale entitlements.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsTest.PartialFailPaddleClient
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Repo

  setup do
    %{account: Fixtures.Accounts.create_account()}
  end

  test "execute/1 refreshes status, period, and recurring price facts from the vendor", %{
    account: account
  } do
    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_sync_1",
        plan: "team",
        status: "past_due",
        current_period_end: nil
      })

    assert :ok = SyncSubscriptions.execute([])

    synced = Repo.reload!(subscription)
    # The stub reports every subscription as active with a fresh period.
    assert synced.status == "active"
    assert %DateTime{} = synced.current_period_end
    assert synced.paddle_price_id == "pri_stub_team_month"
    assert synced.billing_interval == "month"
    assert synced.billing_frequency == 1
    assert synced.quantity == 2
    assert synced.unit_price_amount == 2_000
    assert synced.currency_code == "USD"
  end

  test "execute/1 skips a mirror row with no vendor subscription id", %{account: account} do
    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{plan: "free", status: "none"})

    assert :ok = SyncSubscriptions.execute([])

    assert %Subscription{status: "none"} = Repo.reload!(subscription)
  end

  test "execute/1 reads string-key vendor payload (IL-13 round-trip safe)", %{account: account} do
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

    assert :ok = SyncSubscriptions.execute([])

    synced = Repo.reload!(subscription)
    assert synced.status == "active"
    assert %DateTime{} = synced.current_period_end
  end

  test "execute/1 accepts unused scheduler config without changing the sweep", %{account: account} do
    {:ok, _} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_strkey_args_1",
        plan: "team",
        status: "active"
      })

    assert :ok = SyncSubscriptions.execute(scheduled: true)
  end

  test "execute/1 runs Subject-less — it's a trusted server sweep, not a per-account read",
       %{account: account} do
    # The hourly reconciliation operates on already-trusted server context: it
    # reconciles every mirror row against the vendor with no per-account authz, so
    # its contract is execute/1 — no %Subject{} anywhere on the path. Confirms the
    # documented internal-sweep posture.
    #
    # function_exported?/3 reports false for a module that isn't loaded yet, which
    # the async suite doesn't guarantee — force the load so the arity probe is
    # deterministic rather than racing first-touch.
    assert Code.ensure_loaded?(SyncSubscriptions)
    assert function_exported?(SyncSubscriptions, :execute, 1)
    refute function_exported?(SyncSubscriptions, :execute, 2)

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_nosubj_sweep",
        plan: "team",
        status: "past_due"
      })

    assert :ok = SyncSubscriptions.execute([])
    assert %Subscription{status: "active"} = Repo.reload!(subscription)
  end
end

defmodule Emisar.Billing.Jobs.SyncSubscriptionsVendorFailTest do
  @moduledoc """
  The sweep's one-bad-row-doesn't-abort-the-batch behaviour. Swaps
  `:paddle_client` (process-global) to a client that fails one specific
  subscription id, so this module is `async: false` — a concurrent async test
  calling the Paddle client must not observe the failing client mid-run.
  """
  use Emisar.DataCase, async: false
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsTest.PartialFailPaddleClient
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Repo

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
    # the vendor. execute/1 returns :ok regardless of the per-row failure.
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
        assert :ok = SyncSubscriptions.execute([])
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
defmodule Emisar.Billing.Jobs.SyncSubscriptionsUnknownStatusTest.UnknownStatusPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def retrieve_subscription(id),
    do: {:ok, %{"id" => id, "status" => "some_new_paddle_status"}}

  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def list_products, do: {:error, :unused}
  @impl true
  def list_transactions(_attrs), do: {:error, :unused}
  @impl true
  def get_transaction_invoice(_id), do: {:error, :unused}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.Billing.Jobs.SyncSubscriptionsUnknownStatusTest do
  @moduledoc """
  The sweep persists whatever status Paddle reports. `Subscription.status` is
  deliberately an open `:string` (vendor-owned value space), so a status this
  code has never seen must round-trip into the mirror row rather than failing
  the changeset and 500-ing the sweep. `async: false` — swaps the process-global
  `:paddle_client`.
  """
  use Emisar.DataCase, async: false
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsUnknownStatusTest.UnknownStatusPaddleClient
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Repo

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
  test "execute/1 persists an unrecognized vendor status without crashing" do
    account = Fixtures.Accounts.create_account()

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_unknown_status",
        plan: "team",
        status: "active"
      })

    assert :ok = SyncSubscriptions.execute([])

    assert %Subscription{status: "some_new_paddle_status"} = Repo.reload!(subscription)
  end
end

# A Paddle client that reports a subscription with NO next-billed date (a
# non-renewing / canceled sub), so the sweep's preserve-stored-period behaviour
# can be exercised.
defmodule Emisar.Billing.Jobs.SyncSubscriptionsNoPeriodTest.NoPeriodPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def retrieve_subscription(id), do: {:ok, %{"id" => id, "status" => "active"}}
  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def list_products, do: {:error, :unused}
  @impl true
  def list_transactions(_attrs), do: {:error, :unused}
  @impl true
  def get_transaction_invoice(_id), do: {:error, :unused}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.Billing.Jobs.SyncSubscriptionsNoPeriodTest do
  @moduledoc """
  When Paddle reports a subscription with no next-billed date (a non-renewing /
  canceled sub), the sweep must NOT NULL the stored current_period_end — a paying
  account mid-cancel keeps its "access until" date. `async: false` — swaps the
  process-global `:paddle_client`.
  """
  use Emisar.DataCase, async: false
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsNoPeriodTest.NoPeriodPaddleClient
  alias Emisar.Fixtures
  alias Emisar.Repo

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

  test "execute/1 preserves a stored current_period_end when Paddle reports no next-billed date" do
    account = Fixtures.Accounts.create_account()
    stored = ~U[2026-09-01 00:00:00.000000Z]

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_no_period",
        plan: "team",
        status: "active",
        current_period_end: stored
      })

    assert :ok = SyncSubscriptions.execute([])

    synced = Repo.reload!(subscription)
    assert synced.status == "active"
    # The hourly tick must NOT clobber the access-until date to nil.
    assert synced.current_period_end == stored
  end
end

# A Paddle client whose retrieve fails with a raw HTTP error carrying a response
# body — the shape the live client returns on a non-2xx — so the sweep's error
# log can be checked for payload leakage.
defmodule Emisar.Billing.Jobs.SyncSubscriptionsRedactionTest.HttpErrorPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def retrieve_subscription(_id),
    do: {:error, {:http, 500, ~s({"customer_id":"ctm_secret"})}}

  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def list_products, do: {:error, :unused}
  @impl true
  def list_transactions(_attrs), do: {:error, :unused}
  @impl true
  def get_transaction_invoice(_id), do: {:error, :unused}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.Billing.Jobs.SyncSubscriptionsRedactionTest do
  @moduledoc """
  The sweep's error log must not echo Paddle payload fragments: a non-2xx
  retrieve returns `{:http, status, body}` with the raw vendor body, and that
  body can carry customer ids / amounts. The log line routes through
  `Billing.redacted_paddle_error/1`, which drops the body. `async: false` —
  swaps the process-global `:paddle_client`.
  """
  use Emisar.DataCase, async: false
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsRedactionTest.HttpErrorPaddleClient
  alias Emisar.Fixtures

  setup do
    prev_client = Application.get_env(:emisar, :paddle_client)
    Application.put_env(:emisar, :paddle_client, HttpErrorPaddleClient)

    on_exit(fn ->
      case prev_client do
        nil -> Application.delete_env(:emisar, :paddle_client)
        value -> Application.put_env(:emisar, :paddle_client, value)
      end
    end)

    :ok
  end

  @tag capture_log: true
  test "execute/1 logs the retrieve failure without the raw Paddle response body" do
    import ExUnit.CaptureLog

    account = Fixtures.Accounts.create_account()

    {:ok, _subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_redact_1",
        plan: "team",
        status: "past_due"
      })

    log =
      capture_log(fn ->
        assert :ok = SyncSubscriptions.execute([])
      end)

    # The failure surfaces with its subscription id and HTTP status…
    assert log =~ "billing_sync.retrieve_failed"
    assert log =~ "sub_redact_1"
    assert log =~ "500"

    # …but the raw vendor response body never reaches the log drain.
    refute log =~ "ctm_secret"
  end
end
