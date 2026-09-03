# A Paddle client controlled by process-scoped test config: it can crash one
# retrieval or insert a later row while the current page is being processed.
defmodule Emisar.Billing.Jobs.SyncSubscriptionsTest.ControlledPaddleClient do
  @behaviour Emisar.Billing.PaddleClient
  alias Emisar.{Billing, Config}

  # Not what any of these stubs exercise; the behaviour requires it.
  @impl true
  def cancel_subscription(id), do: {:ok, %{"id" => id, "status" => "canceled"}}

  @impl true
  def retrieve_subscription(id) do
    if id == Config.get_env(:emisar, :billing_sync_test_crash_id) do
      raise "sensitive Paddle payload marker"
    else
      :ok = maybe_insert_later_subscription(id)

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
  def update_subscription(_id, _attrs), do: {:error, :unused}

  @impl true
  def list_subscriptions(attrs) do
    page = Config.get_env(:emisar, :billing_sync_test_discovery_page)

    selected =
      case page do
        %{pages: pages} when is_map(pages) -> Map.fetch!(pages, attrs[:after])
        configured when is_map(configured) -> configured
        nil -> %{subscriptions: [], next_after: nil}
      end

    {:ok, selected}
  end

  @impl true
  def retrieve_transaction(id) do
    {:ok, %{"id" => id, "subscription_id" => String.replace_prefix(id, "txn_", "sub_")}}
  end

  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def list_customers(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def bind_checkout_transaction(_id, _binding), do: {:error, :unused}
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

  defp maybe_insert_later_subscription(id) do
    case Config.get_env(:emisar, :billing_sync_test_insert) do
      %{
        trigger_id: ^id,
        account_id: account_id,
        paddle_subscription_id: paddle_subscription_id
      } ->
        {:ok, _subscription} =
          Billing.upsert_subscription(account_id, %{
            paddle_subscription_id: paddle_subscription_id,
            plan: "team",
            status: "past_due"
          })

        :ok

      _ ->
        :ok
    end
  end
end

defmodule Emisar.Billing.Jobs.SyncSubscriptionsTest do
  @moduledoc """
  The hourly Paddle reconciliation: every mirrored subscription is
  re-fetched from the vendor (the stub here) so a missed webhook can't
  leave an account on stale entitlements.
  """
  use Emisar.DataCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsTest.ControlledPaddleClient
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

    assert SyncSubscriptions.execute([]) == :ok

    synced = Repo.reload!(subscription)
    # The stub reports every subscription as active with a fresh period.
    assert synced.status == "active"
    assert %DateTime{} = synced.current_period_end
    assert synced.paddle_price_id == "pri_stub_team_month"
    assert synced.billing_interval == "month"
    assert synced.billing_frequency == 1
    # The same hourly sweep repairs quantity after mirroring. This account has
    # no runners, so the commercial floor is one rather than Paddle's stale two.
    assert synced.quantity == 1
    assert synced.unit_price_amount == 2_000
    assert synced.currency_code == "USD"
  end

  test "execute/1 keyset-paginates rows added after a full page", %{account: account} do
    Emisar.Config.put_override(:emisar, :paddle_client, ControlledPaddleClient)

    {:ok, _subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_page_first",
        plan: "team",
        status: "past_due"
      })

    later_account = Fixtures.Accounts.create_account()

    Emisar.Config.put_override(:emisar, :billing_sync_test_insert, %{
      trigger_id: "sub_page_first",
      account_id: later_account.id,
      paddle_subscription_id: "sub_page_later"
    })

    assert SyncSubscriptions.execute(limit: 1) == :ok

    later_subscription =
      Subscription.Query.all()
      |> Subscription.Query.by_account_id(later_account.id)
      |> Repo.one()

    assert later_subscription.status == "active"
  end

  test "execute/1 discovers a provider subscription when the created webhook was missed", %{} do
    Emisar.Config.put_override(:emisar, :paddle_client, ControlledPaddleClient)

    account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_missed_created"})

    Emisar.Config.put_override(:emisar, :billing_sync_test_discovery_page, %{
      subscriptions: [
        %{
          "id" => "sub_missed_created",
          "customer_id" => account.paddle_customer_id,
          "custom_data" => %{
            "emisar_account_binding" =>
              Emisar.Crypto.paddle_account_binding(account.id, "txn_missed_created")
          },
          "status" => "active",
          "collection_mode" => "automatic",
          "updated_at" => "2026-08-26T00:00:00Z",
          "items" => [
            %{
              "product" => %{"name" => "team", "custom_data" => %{"plan" => "team"}},
              "price" => %{"id" => "pri_team_01"}
            }
          ]
        }
      ],
      next_after: nil
    })

    assert SyncSubscriptions.execute([]) == :ok

    assert %Subscription{
             paddle_subscription_id: "sub_missed_created",
             status: "active",
             collection_mode: "automatic"
           } =
             Subscription.Query.all()
             |> Subscription.Query.by_account_id(account.id)
             |> Repo.one()
  end

  @tag capture_log: true
  test "a malformed discovery item does not starve the valid items after it", %{} do
    Emisar.Config.put_override(:emisar, :paddle_client, ControlledPaddleClient)

    account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_after_malformed"})

    Emisar.Config.put_override(:emisar, :billing_sync_test_discovery_page, %{
      subscriptions: [
        :malformed,
        %{
          "id" => "sub_after_malformed",
          "customer_id" => account.paddle_customer_id,
          "custom_data" => %{
            "emisar_account_binding" =>
              Emisar.Crypto.paddle_account_binding(account.id, "txn_after_malformed")
          },
          "status" => "active",
          "collection_mode" => "automatic",
          "updated_at" => "2026-08-26T00:00:00Z",
          "items" => [
            %{
              "product" => %{"name" => "team", "custom_data" => %{"plan" => "team"}},
              "price" => %{"id" => "pri_team_01"}
            }
          ]
        }
      ],
      next_after: nil
    })

    assert SyncSubscriptions.execute([]) == :ok

    assert %Subscription{paddle_subscription_id: "sub_after_malformed"} =
             Subscription.Query.all()
             |> Subscription.Query.by_account_id(account.id)
             |> Repo.one()
  end

  test "execute/1 follows provider discovery cursors across pages", %{} do
    Emisar.Config.put_override(:emisar, :paddle_client, ControlledPaddleClient)

    first = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_page_first_01"})
    second = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_page_second_01"})

    subscription = fn id, account ->
      transaction_id = String.replace_prefix(id, "sub_", "txn_")

      %{
        "id" => id,
        "customer_id" => account.paddle_customer_id,
        "custom_data" => %{
          "emisar_account_binding" =>
            Emisar.Crypto.paddle_account_binding(account.id, transaction_id)
        },
        "status" => "active",
        "updated_at" => "2026-08-26T00:00:00Z",
        "items" => [
          %{
            "product" => %{"name" => "team", "custom_data" => %{"plan" => "team"}},
            "price" => %{"id" => "pri_team_01"}
          }
        ]
      }
    end

    Emisar.Config.put_override(:emisar, :billing_sync_test_discovery_page, %{
      pages: %{
        nil => %{
          subscriptions: [subscription.("sub_page_first_01", first)],
          next_after: "sub_page_first_01"
        },
        "sub_page_first_01" => %{
          subscriptions: [subscription.("sub_page_second_01", second)],
          next_after: nil
        }
      }
    })

    assert SyncSubscriptions.execute(limit: 1) == :ok

    for {account, paddle_id} <- [
          {first, "sub_page_first_01"},
          {second, "sub_page_second_01"}
        ] do
      assert %Subscription{paddle_subscription_id: ^paddle_id} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end
  end

  @tag capture_log: true
  test "execute/1 stops and reports a repeated discovery cursor" do
    Emisar.Config.put_override(:emisar, :paddle_client, ControlledPaddleClient)

    Emisar.Config.put_override(:emisar, :billing_sync_test_discovery_page, %{
      pages: %{
        nil => %{subscriptions: [], next_after: "same"},
        "same" => %{subscriptions: [], next_after: "same"}
      }
    })

    log =
      capture_log(fn ->
        assert SyncSubscriptions.execute(limit: 1) == :ok
      end)

    assert log =~ "billing_sync.discovery_failed"
    assert log =~ "non_advancing_cursor"
  end

  test "execute/1 skips a mirror row with no vendor subscription id", %{account: account} do
    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{plan: "free", status: "none"})

    assert SyncSubscriptions.execute([]) == :ok

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

    assert SyncSubscriptions.execute([]) == :ok

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

    assert SyncSubscriptions.execute(scheduled: true) == :ok
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

    assert SyncSubscriptions.execute([]) == :ok
    assert %Subscription{status: "active"} = Repo.reload!(subscription)
  end
end

defmodule Emisar.Billing.Jobs.SyncSubscriptionsVendorFailTest do
  @moduledoc """
  The sweep's one-bad-row-doesn't-abort-the-batch behaviour. Binds a
  `:paddle_client` that fails one specific subscription id via
  `Emisar.Config.put_override/3` — scoped to this test's process, so the suite
  stays `async: true`.
  """
  use Emisar.DataCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsTest.ControlledPaddleClient
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Repo

  setup do
    Emisar.Config.put_override(:emisar, :paddle_client, ControlledPaddleClient)

    :ok
  end

  @tag capture_log: true
  test "a raised retrieve failure is logged safely and the sweep continues to the next row" do
    failing_account = Fixtures.Accounts.create_account()

    {:ok, failing} =
      Billing.upsert_subscription(failing_account.id, %{
        paddle_subscription_id: "sub_fail_row",
        plan: "team",
        status: "past_due",
        current_period_end: nil
      })

    Emisar.Config.put_override(:emisar, :billing_sync_test_crash_id, "sub_fail_row")

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
        assert SyncSubscriptions.execute(limit: 1) == :ok
      end)

    # The per-row rescue lives in `Jobs.Sweep`, shared by every sweep, and names
    # the job plus the row it skipped — never the exception's message, which can
    # carry the vendor payload.
    assert log =~ "sweep.row_failed row=#{failing.id}"
    assert log =~ "job=Emisar.Billing.Jobs.SyncSubscriptions"
    refute log =~ "sensitive Paddle payload marker"
    assert %Subscription{status: "past_due", current_period_end: nil} = Repo.reload!(failing)
    assert %Subscription{status: "active"} = Repo.reload!(ok_row)
  end
end

# A Paddle client that reports a status string this code has never modeled, so
# the sweep's upsert of a vendor-owned status value can be exercised.
defmodule Emisar.Billing.Jobs.SyncSubscriptionsUnknownStatusTest.UnknownStatusPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  # Not what any of these stubs exercise; the behaviour requires it.
  @impl true
  def cancel_subscription(id), do: {:ok, %{"id" => id, "status" => "canceled"}}

  @impl true
  def retrieve_subscription(id),
    do: {:ok, %{"id" => id, "status" => "some_new_paddle_status"}}

  @impl true
  def update_subscription(_id, _attrs), do: {:error, :unused}

  @impl true
  def list_subscriptions(_attrs), do: {:ok, %{subscriptions: [], next_after: nil}}

  @impl true
  def retrieve_transaction(_id), do: {:error, :unused}

  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def list_customers(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def bind_checkout_transaction(_id, _binding), do: {:error, :unused}
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
  the changeset and 500-ing the sweep. Binds `:paddle_client` per-process with
  `Emisar.Config.put_override/3`, so `async: true`.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsUnknownStatusTest.UnknownStatusPaddleClient
  alias Emisar.Billing.Subscription
  alias Emisar.Fixtures
  alias Emisar.Repo

  setup do
    Emisar.Config.put_override(:emisar, :paddle_client, UnknownStatusPaddleClient)

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

    assert SyncSubscriptions.execute([]) == :ok

    assert %Subscription{status: "some_new_paddle_status"} = Repo.reload!(subscription)
  end
end

# A Paddle client that reports a subscription with NO next-billed date (a
# non-renewing / canceled sub), so the sweep's preserve-stored-period behaviour
# can be exercised.
defmodule Emisar.Billing.Jobs.SyncSubscriptionsNoPeriodTest.NoPeriodPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  # Not what any of these stubs exercise; the behaviour requires it.
  @impl true
  def cancel_subscription(id), do: {:ok, %{"id" => id, "status" => "canceled"}}

  @impl true
  def retrieve_subscription(id), do: {:ok, %{"id" => id, "status" => "active"}}
  @impl true
  def update_subscription(_id, _attrs), do: {:error, :unused}
  @impl true
  def list_subscriptions(_attrs), do: {:ok, %{subscriptions: [], next_after: nil}}
  @impl true
  def retrieve_transaction(_id), do: {:error, :unused}
  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def list_customers(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def bind_checkout_transaction(_id, _binding), do: {:error, :unused}
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
  account mid-cancel keeps its "access until" date. Binds `:paddle_client`
  per-process with `Emisar.Config.put_override/3`, so `async: true`.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsNoPeriodTest.NoPeriodPaddleClient
  alias Emisar.Fixtures
  alias Emisar.Repo

  setup do
    Emisar.Config.put_override(:emisar, :paddle_client, NoPeriodPaddleClient)

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

    assert SyncSubscriptions.execute([]) == :ok

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

  # Not what any of these stubs exercise; the behaviour requires it.
  @impl true
  def cancel_subscription(id), do: {:ok, %{"id" => id, "status" => "canceled"}}

  @impl true
  def retrieve_subscription(_id),
    do: {:error, {:http, 500, ~s({"customer_id":"ctm_secret"})}}

  @impl true
  def update_subscription(_id, _attrs), do: {:error, :unused}

  @impl true
  def list_subscriptions(_attrs), do: {:ok, %{subscriptions: [], next_after: nil}}

  @impl true
  def retrieve_transaction(_id), do: {:error, :unused}

  @impl true
  def create_customer(_attrs), do: {:error, :unused}
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def list_customers(_attrs), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}
  @impl true
  def bind_checkout_transaction(_id, _binding), do: {:error, :unused}
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
  `Billing.redacted_paddle_error/1`, which drops the body. Binds `:paddle_client`
  per-process with `Emisar.Config.put_override/3`, so `async: true`.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.SyncSubscriptions
  alias Emisar.Billing.Jobs.SyncSubscriptionsRedactionTest.HttpErrorPaddleClient
  alias Emisar.Fixtures

  setup do
    Emisar.Config.put_override(:emisar, :paddle_client, HttpErrorPaddleClient)

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
        assert SyncSubscriptions.execute([]) == :ok
      end)

    # The failure surfaces with its subscription id and HTTP status…
    assert log =~ "billing_sync.retrieve_failed"
    assert log =~ "sub_redact_1"
    assert log =~ "500"

    # …but the raw vendor response body never reaches the log drain.
    refute log =~ "ctm_secret"
  end
end
