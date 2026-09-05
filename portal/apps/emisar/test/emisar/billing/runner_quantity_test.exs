defmodule Emisar.Billing.RunnerQuantityTest.ControlledPaddleClient do
  @behaviour Emisar.Billing.PaddleClient
  @impl true
  defdelegate cancel_checkout_transaction(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_checkout_transactions(attrs), to: Emisar.Billing.PaddleClient.Stub
  alias Emisar.Config

  @impl true
  def retrieve_subscription(id) do
    send(Config.fetch_env!(:emisar, :runner_quantity_test_pid), {:retrieve_subscription, id})

    case Map.fetch!(Config.fetch_env!(:emisar, :runner_quantity_test_responses), id) do
      {:error, _reason} = error -> error
      response -> {:ok, response}
    end
  end

  @impl true
  def update_subscription(id, attrs) do
    send(Config.fetch_env!(:emisar, :runner_quantity_test_pid), {:update_subscription, id, attrs})
    Config.fetch_env!(:emisar, :runner_quantity_test_update).(id, attrs)
  end

  @impl true
  defdelegate create_customer(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate update_customer(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_customers(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate create_checkout_session(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate bind_checkout_transaction(id, binding), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate create_billing_portal_session(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate retrieve_transaction(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_subscriptions(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate cancel_subscription(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_products(), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_transactions(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate get_transaction_invoice(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true

  defdelegate construct_webhook_event(payload, signature, secret),
    to: Emisar.Billing.PaddleClient.Stub
end

defmodule Emisar.Billing.RunnerQuantityTest do
  use Emisar.DataCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.Billing
  alias Emisar.Billing.Jobs.{SyncRunnerQuantities, SyncSubscriptions}
  alias Emisar.Billing.RunnerQuantityTest.ControlledPaddleClient
  alias Emisar.Fixtures
  alias Emisar.Repo

  @t1 "2026-08-26T10:00:00.000000Z"
  @t2 "2026-08-26T10:01:00.000000Z"
  @t3 "2026-08-26T10:02:00.000000Z"
  @future "2030-08-26T10:00:00.000000Z"

  setup do
    Emisar.Config.put_override(:emisar, :paddle_client, ControlledPaddleClient)
    Emisar.Config.put_override(:emisar, :runner_quantity_test_pid, self())

    Emisar.Config.put_override(
      :emisar,
      :runner_quantity_test_update,
      fn _id, _attrs -> {:error, :unexpected_update} end
    )

    %{account: Fixtures.Accounts.create_account()}
  end

  describe "request_runner_quantity_sync/2" do
    test "marks a Paddle subscription and is a no-op before checkout", %{account: account} do
      assert Billing.request_runner_quantity_sync(account.id, repo: Repo) == {:ok, :requested}

      subscription = create_subscription(account, "sub_request") |> clear_quantity_request()
      assert is_nil(subscription.runner_quantity_sync_requested_at)

      assert Billing.request_runner_quantity_sync(account.id, repo: Repo) == {:ok, :requested}
      assert %DateTime{} = Repo.reload!(subscription).runner_quantity_sync_requested_at
    end
  end

  describe "reconcile_runner_quantity/1" do
    test "a first Paddle subscription starts dirty after runners already exist", %{
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      subscription = create_subscription(account, "sub_first_seen")

      assert %DateTime{} = subscription.runner_quantity_sync_requested_at
    end

    test "floors zero runners to one, changes only Team, and preserves every add-on", %{
      account: account
    } do
      remote = subscription_payload(team_quantity: 4, addon_quantity: 7)
      subscription = create_subscription(account, "sub_absolute")
      configure_responses(%{"sub_absolute" => remote})

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        {:ok, apply_update(remote, id, attrs, @t2)}
      end)

      assert Billing.reconcile_runner_quantity(subscription.id) == {:ok, :updated}

      assert_received {:update_subscription, "sub_absolute", attrs}
      assert attrs["proration_billing_mode"] == "prorated_next_billing_period"
      assert attrs["on_payment_failure"] == "prevent_change"

      assert attrs["items"] == [
               %{"price_id" => "pri_addon", "quantity" => 7},
               %{"price_id" => "pri_team", "quantity" => 1}
             ]

      synced = Repo.reload!(subscription)
      assert synced.quantity == 1
      assert synced.paddle_updated_at == parse_time(@t2)
      assert is_nil(synced.runner_quantity_sync_requested_at)
    end

    test "an equal absolute quantity clears dirty without another billable update", %{
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      subscription = create_subscription(account, "sub_equal")
      configure_responses(%{"sub_equal" => subscription_payload(team_quantity: 1)})

      assert Billing.reconcile_runner_quantity(subscription.id) == {:ok, :converged}
      refute_received {:update_subscription, _, _}
      assert is_nil(Repo.reload!(subscription).runner_quantity_sync_requested_at)
    end

    test "uses the resolved proration mode for active, trial, and scheduled final periods" do
      cases = [
        {"ordinary", "active", nil, "automatic", "prorated_next_billing_period"},
        {"manual_ordinary", "active", nil, "manual", "prorated_next_billing_period"},
        {"trial", "trialing", nil, "automatic", "do_not_bill"},
        {"manual_trial", "trialing", nil, "manual", "do_not_bill"},
        {"cancel", "active", scheduled_change("cancel"), "automatic", "prorated_immediately"},
        {"manual_pause", "active", scheduled_change("pause"), "manual", "prorated_immediately"}
      ]

      responses =
        Map.new(cases, fn {name, status, scheduled_change, collection_mode, _mode} ->
          id = "sub_mode_#{name}"
          account = Fixtures.Accounts.create_account()
          Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
          create_subscription(account, id)

          {id,
           subscription_payload(
             status: status,
             collection_mode: collection_mode,
             scheduled_change: scheduled_change,
             team_quantity: 2
           )}
        end)

      configure_responses(responses)

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        {:ok, apply_update(Map.fetch!(responses, id), id, attrs, @t2)}
      end)

      for {name, _status, _scheduled_change, _collection_mode, expected_mode} <- cases do
        id = "sub_mode_#{name}"
        subscription = subscription_by_paddle_id(id)
        assert Billing.reconcile_runner_quantity(subscription.id) == {:ok, :updated}
        assert_received {:update_subscription, ^id, %{"proration_billing_mode" => ^expected_mode}}
      end
    end

    test "past-due, paused, invalid, and unknown scheduled states stay dirty without PATCH" do
      cases = [
        {"past_due", [status: "past_due"]},
        {"paused", [status: "paused"]},
        {"missing_deadline", [scheduled_change: %{"action" => "cancel"}]},
        {"malformed_deadline",
         [scheduled_change: %{"action" => "pause", "effective_at" => "not-a-time"}]},
        {"expired_deadline",
         [scheduled_change: %{"action" => "cancel", "effective_at" => "2020-01-01T00:00:00Z"}]},
        {"unknown_schedule", [scheduled_change: %{"action" => "new_vendor_action"}]},
        {"unknown_status", [status: "new_vendor_status"]}
      ]

      responses =
        Map.new(cases, fn {name, opts} ->
          id = "sub_defer_#{name}"
          account = Fixtures.Accounts.create_account()
          subscription = create_subscription(account, id)
          clear_quantity_request(subscription)
          {id, subscription_payload(opts)}
        end)

      configure_responses(responses)

      for {name, _opts} <- cases do
        id = "sub_defer_#{name}"
        subscription = subscription_by_paddle_id(id)
        assert Billing.reconcile_runner_quantity(subscription.id) == {:ok, :deferred}
        assert %DateTime{} = Repo.reload!(subscription).runner_quantity_sync_requested_at
      end

      refute_received {:update_subscription, _, _}
    end

    test "ambiguous or missing Team products fail closed and retain dirty", %{account: account} do
      subscription = create_subscription(account, "sub_ambiguous")
      team = team_item(2)

      for items <- [
            [addon_item(1)],
            [team, put_in(team, ["price", "id"], "pri_team_2")],
            [team, other_plan_item(1)]
          ] do
        configure_responses(%{
          "sub_ambiguous" => subscription_payload(items: items)
        })

        assert Billing.reconcile_runner_quantity(subscription.id) ==
                 {:error, :ambiguous_subscription_items}

        assert %DateTime{} = Repo.reload!(subscription).runner_quantity_sync_requested_at
      end

      refute_received {:update_subscription, _, _}
    end

    test "an add-on-only lifecycle payload preserves the last known plan item and requests repair",
         %{
           account: account
         } do
      subscription =
        account
        |> create_subscription("sub_ambiguous_mirror")
        |> clear_quantity_request()

      assert is_nil(subscription.runner_quantity_sync_requested_at)

      assert {:ok, mirrored} =
               Billing.reconcile_subscription_data(
                 subscription_payload(
                   id: "sub_ambiguous_mirror",
                   items: [addon_item(9)]
                 ),
                 expected_subscription: subscription
               )

      assert mirrored.plan == "team"
      assert mirrored.paddle_price_id == "pri_team"
      assert mirrored.quantity == 1
      assert %DateTime{} = mirrored.runner_quantity_sync_requested_at
    end

    test "a PATCH response must preserve the complete requested item set", %{account: account} do
      remote = subscription_payload(team_quantity: 4, addon_quantity: 7)
      subscription = create_subscription(account, "sub_response_contract")
      configure_responses(%{"sub_response_contract" => remote})

      transforms = [
        &response_without_addon/1,
        &response_with_changed_addon/1,
        &response_with_duplicate_addon/1
      ]

      for transform <- transforms do
        Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
          {:ok, transform.(apply_update(remote, id, attrs, @t2))}
        end)

        assert Billing.reconcile_runner_quantity(subscription.id) ==
                 {:error, :quantity_update_not_applied}

        assert %DateTime{} = Repo.reload!(subscription).runner_quantity_sync_requested_at
      end
    end

    test "a provider-applied timeout recovers by GET equality without a second PATCH", %{
      account: account
    } do
      remote = subscription_payload(team_quantity: 4)
      subscription = create_subscription(account, "sub_timeout")
      configure_responses(%{"sub_timeout" => remote})

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        applied = apply_update(remote, id, attrs, @t2)
        configure_responses(%{id => applied})
        {:error, :timeout}
      end)

      assert Billing.reconcile_runner_quantity(subscription.id) == {:error, :timeout}
      assert %DateTime{} = Repo.reload!(subscription).runner_quantity_sync_requested_at

      assert Billing.reconcile_runner_quantity(subscription.id) == {:ok, :converged}
      assert is_nil(Repo.reload!(subscription).runner_quantity_sync_requested_at)
      assert_received {:update_subscription, "sub_timeout", _attrs}
      refute_received {:update_subscription, "sub_timeout", _attrs}
    end

    test "a sync request stamped while Paddle is called survives the convergence", %{
      account: account
    } do
      remote = subscription_payload(id: "sub_midflight_marker", team_quantity: 4)
      subscription = create_subscription(account, "sub_midflight_marker")
      configure_responses(%{"sub_midflight_marker" => remote})

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        # The row is not locked across the Paddle calls, so a runner transition
        # can land here and stamp a fresh marker.
        {:ok, :requested} = Billing.request_runner_quantity_sync(account.id, repo: Repo)
        {:ok, apply_update(remote, id, attrs, @t2)}
      end)

      assert Billing.reconcile_runner_quantity(subscription.id) == {:ok, :updated}

      synced = Repo.reload!(subscription)
      assert synced.quantity == 1
      assert synced.paddle_updated_at == parse_time(@t2)

      # Clearing a marker this pass never acted on would lose that transition's
      # quantity until the next hourly sweep, so only the read marker is cleared.
      assert %DateTime{} = synced.runner_quantity_sync_requested_at

      refute synced.runner_quantity_sync_requested_at ==
               subscription.runner_quantity_sync_requested_at
    end

    test "a newer stored timestamp landing mid-PATCH is not rewound", %{account: account} do
      remote = subscription_payload(id: "sub_midflight_webhook", team_quantity: 4)
      subscription = create_subscription(account, "sub_midflight_webhook")
      configure_responses(%{"sub_midflight_webhook" => remote})

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        {:ok, _mirrored} =
          Billing.reconcile_subscription_data(
            subscription_payload(id: id, team_quantity: 3, updated_at: @t3),
            expected_subscription: subscription
          )

        {:ok, apply_update(remote, id, attrs, @t2)}
      end)

      assert Billing.reconcile_runner_quantity(subscription.id) ==
               {:error, :stale_subscription_snapshot}

      synced = Repo.reload!(subscription)
      assert synced.quantity == 3
      assert synced.paddle_updated_at == parse_time(@t3)
      assert %DateTime{} = synced.runner_quantity_sync_requested_at
    end

    test "a delayed webhook cannot rewind quantity after a successful PATCH", %{account: account} do
      remote = subscription_payload(team_quantity: 4)
      subscription = create_subscription(account, "sub_ordered")
      configure_responses(%{"sub_ordered" => remote})

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        {:ok, apply_update(remote, id, attrs, @t2)}
      end)

      assert Billing.reconcile_runner_quantity(subscription.id) == {:ok, :updated}

      delayed =
        subscription_payload(team_quantity: 99, updated_at: @t1)
        |> Map.put("id", "sub_ordered")

      assert Billing.record_and_apply_event(
               "evt_quantity_delayed",
               "subscription.updated",
               %{
                 "event_id" => "evt_quantity_delayed",
                 "event_type" => "subscription.updated",
                 "occurred_at" => @t3,
                 "data" => delayed
               }
             ) == :ok

      synced = Repo.reload!(subscription)
      assert synced.quantity == 1
      assert synced.paddle_updated_at == parse_time(@t2)
    end

    test "an accepted canceled mirror clears dirty even when no worker will scan it", %{
      account: account
    } do
      subscription = create_subscription(account, "sub_canceled")

      assert {:ok, canceled} =
               Billing.reconcile_subscription_data(
                 subscription_payload(status: "canceled", updated_at: @t2)
                 |> Map.put("id", "sub_canceled"),
                 expected_subscription: subscription
               )

      assert canceled.status == "canceled"
      assert is_nil(canceled.runner_quantity_sync_requested_at)
    end
  end

  describe "repair jobs" do
    test "the hourly full sweep repairs unmarked quantity drift", %{account: account} do
      subscription = create_subscription(account, "sub_hourly") |> clear_quantity_request()
      remote = subscription_payload(id: "sub_hourly", team_quantity: 5)
      configure_responses(%{"sub_hourly" => remote})

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        {:ok, apply_update(remote, id, attrs, @t2)}
      end)

      assert SyncSubscriptions.execute([]) == :ok
      assert_received {:update_subscription, "sub_hourly", _attrs}
      synced = Repo.reload!(subscription)
      assert synced.quantity == 1
      assert synced.paddle_price_id == "pri_team"
      assert synced.unit_price_amount == 2_000
      assert synced.entitlements["runners_limit"] == 100
    end

    test "one failed dirty subscription does not starve a later row" do
      first_account = Fixtures.Accounts.create_account()
      second_account = Fixtures.Accounts.create_account()
      first = create_subscription(first_account, "sub_job_first")
      second = create_subscription(second_account, "sub_job_second")

      configure_responses(%{
        "sub_job_first" => {:error, :paddle_unavailable},
        "sub_job_second" => subscription_payload(team_quantity: 3)
      })

      Emisar.Config.put_override(:emisar, :runner_quantity_test_update, fn id, attrs ->
        remote = subscription_payload(team_quantity: 3)
        {:ok, apply_update(remote, id, attrs, @t2)}
      end)

      log = capture_log(fn -> assert SyncRunnerQuantities.execute(limit: 1) == :ok end)

      assert log =~ "billing_runner_quantity_sync.failed"
      assert %DateTime{} = Repo.reload!(first).runner_quantity_sync_requested_at
      assert is_nil(Repo.reload!(second).runner_quantity_sync_requested_at)
    end
  end

  defp create_subscription(account, paddle_id) do
    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: paddle_id,
        paddle_price_id: "pri_team",
        plan: "team",
        status: "active",
        collection_mode: "automatic",
        quantity: 1
      })

    subscription
  end

  defp clear_quantity_request(subscription) do
    {:ok, cleared} =
      Billing.upsert_subscription(subscription.account_id, %{
        paddle_subscription_id: subscription.paddle_subscription_id,
        runner_quantity_sync_requested_at: nil
      })

    cleared
  end

  defp subscription_by_paddle_id(id) do
    Billing.Subscription.Query.all()
    |> Billing.Subscription.Query.by_paddle_subscription_id(id)
    |> Repo.fetch!(Billing.Subscription.Query)
  end

  defp configure_responses(responses) do
    Emisar.Config.put_override(:emisar, :runner_quantity_test_responses, responses)
  end

  defp subscription_payload(opts) do
    items =
      Keyword.get(opts, :items, [
        addon_item(Keyword.get(opts, :addon_quantity, 1)),
        team_item(Keyword.get(opts, :team_quantity, 2))
      ])

    %{
      "id" => Keyword.get(opts, :id, "sub_remote"),
      "status" => Keyword.get(opts, :status, "active"),
      "collection_mode" => Keyword.get(opts, :collection_mode, "automatic"),
      "scheduled_change" => Keyword.get(opts, :scheduled_change),
      "updated_at" => Keyword.get(opts, :updated_at, @t1),
      "items" => items
    }
  end

  defp team_item(quantity) do
    %{
      "quantity" => quantity,
      "product" => %{
        "name" => "Team",
        "custom_data" => %{"plan" => "team", "runners_limit" => "100"}
      },
      "price" => %{
        "id" => "pri_team",
        "billing_cycle" => %{"interval" => "month", "frequency" => 1},
        "unit_price" => %{"amount" => "2000", "currency_code" => "USD"}
      }
    }
  end

  defp addon_item(quantity) do
    %{
      "quantity" => quantity,
      "product" => %{"name" => "Support add-on", "custom_data" => %{}},
      "price" => %{
        "id" => "pri_addon",
        "billing_cycle" => %{"interval" => "month", "frequency" => 1},
        "unit_price" => %{"amount" => "500", "currency_code" => "USD"}
      }
    }
  end

  defp other_plan_item(quantity) do
    quantity
    |> addon_item()
    |> put_in(["product", "custom_data", "plan"], "enterprise")
    |> put_in(["price", "id"], "pri_enterprise")
  end

  defp scheduled_change(action) do
    %{"action" => action, "effective_at" => @future}
  end

  defp response_without_addon(updated), do: Map.put(updated, "items", [team_item(1)])

  defp response_with_changed_addon(updated) do
    put_in(updated, ["items", Access.at(0), "quantity"], 8)
  end

  defp response_with_duplicate_addon(updated) do
    Map.update!(updated, "items", fn [addon, team] -> [addon, addon, team] end)
  end

  defp apply_update(remote, id, attrs, updated_at) do
    quantities = Map.new(attrs["items"], &{&1["price_id"], &1["quantity"]})

    items =
      Enum.map(remote["items"], fn item ->
        put_in(item, ["quantity"], Map.fetch!(quantities, get_in(item, ["price", "id"])))
      end)

    remote
    |> Map.put("id", id)
    |> Map.put("items", items)
    |> Map.put("updated_at", updated_at)
  end

  defp parse_time(iso) do
    {:ok, datetime, 0} = DateTime.from_iso8601(iso)
    datetime
  end
end
