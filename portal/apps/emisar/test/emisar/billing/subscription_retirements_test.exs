defmodule Emisar.Billing.SubscriptionRetirementsTest do
  use Emisar.DataCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.{Accounts, Billing, Config, Fixtures, Repo}
  alias Emisar.Billing.{CheckoutIntent, Subscription, SubscriptionRetirements}
  alias Emisar.Billing.Jobs.SyncSubscriptions

  setup do
    store = Fixtures.Billing.start_provider()
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    {:ok, _customer, account} = Billing.ensure_paddle_customer(account, subject)
    %{account: account, subject: subject, store: store}
  end

  test "conflict and webhook dedup commit before cancellation, even when cancellation fails", %{
    account: account
  } do
    first = paid_subscription(account)
    duplicate = paid_subscription(account)
    assert :ok = deliver(first)
    event_id = "evt_" <> Ecto.UUID.generate()

    assert :ok = deliver(duplicate, event_id)
    retirement = SubscriptionRetirements.find(duplicate["id"])
    assert retirement.state == :pending
    assert retirement.transaction_id == duplicate["transaction_id"]
    assert mirror(account).paddle_subscription_id == first["id"]
    refute_received {:paddle, :cancel_subscription, _id, _caller}

    duplicate_id = duplicate["id"]

    Config.put_override(:emisar, :billing_test_after_call, fn
      :get_subscription, ^duplicate_id, _result -> {:error, :timeout}
      _operation, _args, result -> result
    end)

    assert {:error, :subscription_retirement_pending} =
             SubscriptionRetirements.recover(retirement)

    assert Repo.reload!(retirement).state == :pending
    assert {:duplicate, ^event_id} = deliver(duplicate, event_id)
    assert mirror(account).paddle_subscription_id == first["id"]
  end

  test "a signed updated event without transaction_id uses exact provider proof", %{
    account: account
  } do
    first = paid_subscription(account)
    duplicate = paid_subscription(account)
    assert :ok = deliver(first)

    event = %{
      "event_type" => "subscription.updated",
      "data" => Map.delete(duplicate, "transaction_id")
    }

    assert :ok = Fixtures.Billing.deliver_event(event)
    retirement = SubscriptionRetirements.find(duplicate["id"])
    assert retirement.subscription_id == duplicate["id"]
    assert mirror(account).paddle_subscription_id == first["id"]
  end

  test "either webhook order preserves its first canonical and retires only the other subscription" do
    for reverse? <- [false, true] do
      account =
        Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_" <> Ecto.UUID.generate()})

      subscriptions = [paid_subscription(account), paid_subscription(account)]
      [first, second] = if reverse?, do: Enum.reverse(subscriptions), else: subscriptions
      assert :ok = deliver(first)
      assert :ok = deliver(second)
      assert mirror(account).paddle_subscription_id == first["id"]
      assert is_nil(SubscriptionRetirements.find(first["id"]))
      retirement = SubscriptionRetirements.find(second["id"])
      assert {:ok, confirmed} = SubscriptionRetirements.recover(retirement)
      assert confirmed.state == :confirmed

      assert {:ok, %{"status" => "active"}} =
               Billing.PaddleClient.retrieve_subscription(first["id"])
    end
  end

  test "paused duplicates are canceled and retained IDs refuse delayed adoption", %{
    account: account
  } do
    first = paid_subscription(account)
    duplicate = paid_subscription(account, %{"status" => "paused"})
    assert :ok = deliver(first)
    assert :ok = deliver(duplicate)
    retirement = SubscriptionRetirements.find(duplicate["id"])

    assert {:ok, confirmed} = SubscriptionRetirements.recover(retirement)
    assert confirmed.state == :confirmed
    assert {:ok, ^confirmed} = SubscriptionRetirements.recover(confirmed)
    assert_received {:paddle, :cancel_subscription, _id, _caller}
    refute_received {:paddle, :cancel_subscription, _id, _caller}
    assert :ok = deliver(Map.put(duplicate, "status", "active"))
    assert mirror(account).paddle_subscription_id == first["id"]
    assert SubscriptionRetirements.find(duplicate["id"]).state == :confirmed
  end

  test "unknown canonical status or unavailable canonical cannot authorize retirement", %{
    account: account
  } do
    first = paid_subscription(account)
    duplicate = paid_subscription(account)
    assert :ok = deliver(first)
    Fixtures.Billing.set_subscription(first["id"], %{"status" => "unknown"})

    assert {:error, {:apply_failed, :invalid_canonical_subscription}} = deliver(duplicate)
    assert is_nil(SubscriptionRetirements.find(duplicate["id"]))
    assert mirror(account).paddle_subscription_id == first["id"]

    first_id = first["id"]

    Config.put_override(:emisar, :billing_test_after_call, fn
      :get_subscription, ^first_id, _result -> {:error, :not_found}
      _operation, _args, result -> result
    end)

    assert {:error, {:apply_failed, :not_found}} = deliver(duplicate)
    assert is_nil(SubscriptionRetirements.find(duplicate["id"]))
    refute_received {:paddle, :cancel_subscription, _id, _caller}
  end

  test "a stale active canonical is refreshed and its canceled state permits replacement", %{
    account: account
  } do
    first = paid_subscription(account, %{"updated_at" => "2026-09-01T00:00:00Z"})
    candidate = paid_subscription(account, %{"updated_at" => "2026-09-02T00:00:00Z"})
    assert :ok = deliver(first)

    Fixtures.Billing.set_subscription(first["id"], %{
      "status" => "canceled",
      "updated_at" => "2026-09-04T00:00:00Z"
    })

    assert :ok = deliver(candidate)
    assert mirror(account).paddle_subscription_id == candidate["id"]
    assert mirror(account).status == "active"
    assert is_nil(SubscriptionRetirements.find(candidate["id"]))
  end

  test "replacement starts clean provider fields and clocks on the persisted local row", %{
    account: account
  } do
    old =
      Fixtures.Accounts.create_subscription(account, "enterprise",
        paddle_subscription_id: "sub_previous",
        status: "canceled",
        paddle_updated_at: ~U[2026-10-01 00:00:00Z],
        paddle_event_occurred_at: ~U[2026-10-01 00:00:00Z],
        entitlements: %{"features_scim_enabled?" => true},
        scheduled_change_action: "pause",
        scheduled_change_effective_at: ~U[2026-10-02 00:00:00Z],
        cancel_at_period_end: true,
        trial_end: ~U[2026-09-20 00:00:00Z],
        current_period_start: ~U[2026-09-01 00:00:00Z]
      )

    candidate =
      paid_subscription(account, %{
        "updated_at" => "2026-09-02T00:00:00Z",
        "scheduled_change" => nil
      })

    assert :ok = deliver(candidate)
    replacement = mirror(account)
    assert replacement.id == old.id
    assert replacement.plan == "team"
    assert replacement.entitlements == %{}
    assert replacement.paddle_updated_at == ~U[2026-09-02 00:00:00.000000Z]
    assert replacement.paddle_event_occurred_at == ~U[2026-09-02 00:00:00.000000Z]
    assert is_nil(replacement.scheduled_change_action)
    assert is_nil(replacement.scheduled_change_effective_at)
    assert is_nil(replacement.trial_end)
    assert is_nil(replacement.current_period_start)
    refute replacement.cancel_at_period_end
  end

  test "a complimentary mirror converts to the verified paid plan", %{account: account} do
    old =
      Fixtures.Accounts.create_subscription(account, "enterprise",
        status: "complimentary",
        entitlements: %{"features_scim_enabled?" => true}
      )

    candidate = paid_subscription(account)
    assert :ok = deliver(candidate)
    assert mirror(account).id == old.id
    assert mirror(account).plan == "team"
    assert mirror(account).entitlements == %{}
    assert is_nil(SubscriptionRetirements.find(candidate["id"]))
  end

  test "delayed active receipt uses the verified current canceled candidate", %{account: account} do
    candidate = paid_subscription(account)
    Fixtures.Billing.set_subscription(candidate["id"], %{"status" => "canceled"})
    assert :ok = deliver(candidate)
    assert mirror(account).status == "canceled"
  end

  test "forged binding, wrong event transaction, and mismatched customer never queue cancellation",
       %{account: account} do
    first = paid_subscription(account)
    candidate = paid_subscription(account)
    assert :ok = deliver(first)

    for invalid <- [
          put_in(candidate, ["custom_data", "emisar_account_binding"], "forged"),
          Map.put(candidate, "transaction_id", "txn_other"),
          Map.put(candidate, "customer_id", "ctm_other")
        ] do
      assert {:error, {:apply_failed, :invalid_subscription_account_binding}} = deliver(invalid)
    end

    assert is_nil(SubscriptionRetirements.find(candidate["id"]))
    refute_received {:paddle, :cancel_subscription, _id, _caller}
  end

  test "shared customer does not let a signed candidate replace another account", %{
    account: account
  } do
    other = Fixtures.Accounts.create_account(%{paddle_customer_id: account.paddle_customer_id})
    candidate = paid_subscription(other)
    assert :ok = deliver(candidate)
    assert is_nil(mirror(account))
    assert mirror(other).paddle_subscription_id == candidate["id"]
    assert is_nil(SubscriptionRetirements.find(candidate["id"]))
  end

  test "paid checkout reconciliation permits legitimate current subscription item changes", %{
    account: account,
    subject: subject
  } do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    intent = account.id |> CheckoutIntent.Query.by_account_id() |> Repo.peek()
    candidate = Fixtures.Billing.complete_transaction(intent.transaction_id)
    item = hd(candidate["items"])

    Fixtures.Billing.set_subscription(candidate["id"], %{
      "items" => [Map.put(item, "quantity", 17)]
    })

    assert {:ok, recovered} = Billing.Checkouts.recover(intent)
    assert recovered.state == :subscribed
    assert mirror(account).quantity == 17
    assert mirror(account).paddle_subscription_id == candidate["id"]
  end

  test "close confirms the pending unpaid transaction", %{
    account: account,
    subject: subject
  } do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    intent = account.id |> CheckoutIntent.Query.by_account_id() |> Repo.peek()
    assert {:ok, closed} = Accounts.close_account(account.id, "Leaving", subject)
    assert closed.deleted_at
    assert Repo.reload!(intent).state == :canceled
  end

  test "late closed-account subscription with a former canonical queues durable cleanup", %{
    account: account,
    subject: subject
  } do
    first = paid_subscription(account)
    late = paid_subscription(account)
    assert :ok = deliver(first)
    assert {:ok, _closed} = Accounts.close_account(account.id, "Leaving", subject)
    assert mirror(account).status == "canceled"

    assert :ok = deliver(late)
    retirement = SubscriptionRetirements.find(late["id"])
    assert retirement.reason == :account_closed
    assert mirror(account).paddle_subscription_id == first["id"]
    assert {:ok, confirmed} = SubscriptionRetirements.recover(retirement)
    assert confirmed.state == :confirmed
  end

  test "hard erasure retains pending intent and retirement work without account audit FK", %{
    account: account,
    subject: subject
  } do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    intent = account.id |> CheckoutIntent.Query.by_account_id() |> Repo.peek()
    pending = paid_subscription(account)
    retirement = Fixtures.Billing.create_retirement(account, pending)
    assert {:ok, _erased} = Accounts.delete_by_id(account.id)

    assert {:ok, recovered} = Billing.Checkouts.recover(intent)
    assert recovered.state == :canceled
    assert {:ok, confirmed} = SubscriptionRetirements.recover(retirement)
    assert confirmed.state == :confirmed
    assert Repo.reload!(retirement)
    assert is_nil(mirror(account))
  end

  test "a subscription first received after hard erasure is queued and not adopted", %{
    account: account
  } do
    candidate = paid_subscription(account)
    assert {:ok, _erased} = Accounts.delete_by_id(account.id)
    assert :ok = deliver(candidate)
    retirement = SubscriptionRetirements.find(candidate["id"])
    assert retirement.reason == :account_erased
    assert {:ok, confirmed} = SubscriptionRetirements.recover(retirement)
    assert confirmed.state == :confirmed
    assert is_nil(mirror(account))
  end

  test "twice-run sweep completes retirement despite cyclic discovery", %{account: account} do
    candidate = paid_subscription(account)
    retirement = Fixtures.Billing.create_retirement(account, candidate)

    Config.put_override(:emisar, :billing_test_after_call, fn
      :list_subscriptions, _args, _result -> {:ok, %{subscriptions: [], next_after: "sub_repeat"}}
      _operation, _args, result -> result
    end)

    log =
      capture_log(fn ->
        assert :ok = SyncSubscriptions.execute(limit: 1)
        assert :ok = SyncSubscriptions.execute(limit: 1)
      end)

    assert log =~ "billing_sync.discovery_failed"
    assert Repo.reload!(retirement).state == :confirmed
    assert_received {:paddle, :cancel_subscription, _id, _caller}
    refute_received {:paddle, :cancel_subscription, _id, _caller}
  end

  defp paid_subscription(account, attrs \\ %{}) do
    transaction = Fixtures.Billing.create_legacy_transaction(account)
    Fixtures.Billing.complete_transaction(transaction["id"], attrs)
  end

  test "raising or endlessly advancing discovery cannot starve durable cleanup", %{
    account: account
  } do
    for failure <- [:raise, :page_limit] do
      subscription = paid_subscription(account)
      retirement = Fixtures.Billing.create_retirement(account, subscription)
      Process.put(:discovery_pages, 0)

      Config.put_override(:emisar, :billing_test_after_call, fn
        :list_subscriptions, _args, _result ->
          page = Process.get(:discovery_pages) + 1
          Process.put(:discovery_pages, page)

          if failure == :raise do
            raise "provider response must not escape into logs"
          else
            {:ok, %{subscriptions: [], next_after: "sub_page_#{page}"}}
          end

        _, _, result ->
          result
      end)

      log = capture_log(fn -> assert :ok = SyncSubscriptions.execute(limit: 1) end)
      assert log =~ "billing_sync.discovery_failed"
      refute log =~ "provider response must not escape"
      assert Process.get(:discovery_pages) == if(failure == :raise, do: 1, else: 100)
      assert Repo.reload!(retirement).state == :confirmed
    end
  end

  test "the sweep recovers committed create work before discovery and is repeatable", %{
    account: account
  } do
    intent = Fixtures.Billing.create_checkout_intent(account)

    assert {:ok, transaction} =
             Billing.PaddleClient.create_checkout_session(%{
               customer: account.paddle_customer_id,
               price_id: intent.price_id,
               quantity: intent.quantity,
               custom_data: %{"emisar_checkout_intent" => intent.id}
             })

    Config.put_override(:emisar, :billing_test_before_call, fn
      :list_subscriptions, _args -> assert Repo.reload!(intent).state == :payable
      _, _ -> :ok
    end)

    assert :ok = SyncSubscriptions.execute(limit: 1)
    assert :ok = SyncSubscriptions.execute(limit: 1)
    assert Repo.reload!(intent).transaction_id == transaction["id"]
    assert_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :create, _attrs, _caller}
  end

  defp deliver(subscription, event_id \\ "evt_" <> Ecto.UUID.generate()) do
    type = "subscription.created"

    Billing.record_and_apply_event(event_id, type, %{"event_type" => type, "data" => subscription})
  end

  defp mirror(account) do
    Subscription.Query.all() |> Subscription.Query.by_account_id(account.id) |> Repo.peek()
  end
end
