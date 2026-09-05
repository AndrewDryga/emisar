defmodule Emisar.Billing.CheckoutConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Billing, Config, Fixtures, Repo, Users}
  alias Emisar.Billing.{CheckoutIntent, ProcessedEvent, Subscription, SubscriptionRetirements}
  alias Emisar.Fixtures.Billing.Provider

  @moduletag timeout: 60_000

  setup do
    %{store: Fixtures.Billing.start_provider()}
  end

  test "two completed first scans on separate connections grant exactly one POST", %{store: store} do
    unboxed_account(store, fn state ->
      parent = self()

      after_call = fn
        :list_transactions, attrs, result ->
          if is_nil(attrs[:created_after]) and not Process.get(:initial_scan_done, false) do
            Process.put(:initial_scan_done, true)
            send(parent, {:scanned, self(), backend_pid()})

            receive do
              :continue_scan -> :ok
            end
          end

          result

        _operation, _args, result ->
          result
      end

      before_call = fn
        :create, _attrs ->
          send(parent, {:post_winner, self()})

          receive do
            :continue_post -> :ok
          end

        _operation, _args ->
          :ok
      end

      first = checkout_task(state, before_call, after_call)
      second = checkout_task(%{state | subject: state.second_subject}, before_call, after_call)

      try do
        assert_receive {:scanned, first_pid, first_backend}, 5_000
        assert_receive {:scanned, second_pid, second_backend}, 5_000
        assert first_backend != second_backend
        send(first_pid, :continue_scan)
        send(second_pid, :continue_scan)
        assert_receive {:post_winner, winner}, 5_000
        loser = if first.pid == winner, do: second, else: first
        winning_task = if first.pid == winner, do: first, else: second
        assert Task.await(loser, 10_000) == {:error, :checkout_pending}
        assert Repo.aggregate(CheckoutIntent.Query.by_account_id(state.account.id), :count) == 1
        send(winner, :continue_post)
        assert {:ok, url} = Task.await(winning_task, 10_000)
        assert Billing.start_checkout(state.account, "team", :month, state.subject) == {:ok, url}
        assert_received {:paddle, :create, _attrs, _caller}
        refute_received {:paddle, :create, _attrs, _caller}
      after
        stop_tasks([first, second])
      end
    end)
  end

  test "worker loss after accepted POST recovers from committed reservation", %{store: store} do
    unboxed_account(store, fn state ->
      parent = self()

      after_call = fn
        :create, _attrs, result ->
          send(parent, {:accepted, self()})

          receive do
            :never_release -> result
          end

        _operation, _args, result ->
          result
      end

      worker = checkout_task(state, fn _operation, _args -> :ok end, after_call)

      try do
        assert_receive {:accepted, _worker}, 5_000
        assert current_intent(state.account).state == :creating
        Task.shutdown(worker, :brutal_kill)
        assert {:ok, _url} = Billing.start_checkout(state.account, "team", :month, state.subject)
        assert current_intent(state.account).state == :payable
        assert_received {:paddle, :create, _attrs, _caller}
        refute_received {:paddle, :create, _attrs, _caller}
      after
        stop_tasks([worker])
      end
    end)
  end

  test "a real DB failure after accepted POST leaves a recoverable creating row", %{store: store} do
    unboxed_account(store, fn state ->
      parent = self()

      after_call = fn
        :create, attrs, result ->
          send(
            parent,
            {:accepted_before_capture, self(), attrs.custom_data["emisar_checkout_intent"]}
          )

          receive do
            :continue_capture -> result
          end

        _operation, _args, result ->
          result
      end

      worker =
        unboxed_task(fn ->
          configure_provider(state.store, fn _operation, _args -> :ok end, after_call)

          try do
            Billing.start_checkout(state.account, "team", :month, state.subject)
          rescue
            error in Ecto.ConstraintError -> {:raised, error.__struct__}
          end
        end)

      constraint = "checkout_capture_" <> String.replace(Ecto.UUID.generate(), "-", "")

      try do
        assert_receive {:accepted_before_capture, worker_pid, intent_id}, 5_000
        assert {:ok, _uuid} = Ecto.UUID.cast(intent_id)

        Repo.query!(
          "ALTER TABLE billing_checkout_intents ADD CONSTRAINT #{constraint} CHECK (id != '#{intent_id}'::uuid OR state != 'binding')"
        )

        send(worker_pid, :continue_capture)
        assert Task.await(worker, 10_000) == {:raised, Ecto.ConstraintError}
        assert current_intent(state.account).state == :creating
      after
        stop_tasks([worker])

        Repo.query!(
          "ALTER TABLE billing_checkout_intents DROP CONSTRAINT IF EXISTS #{constraint}"
        )
      end

      assert {:ok, _url} = Billing.start_checkout(state.account, "team", :month, state.subject)
      assert_received {:paddle, :create, _attrs, _caller}
      refute_received {:paddle, :create, _attrs, _caller}
    end)
  end

  test "subscription proof and closure provider calls run outside database transactions", %{
    store: store
  } do
    unboxed_account(store, fn state ->
      transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      subscription = Fixtures.Billing.complete_transaction(transaction["id"])

      Config.put_override(:emisar, :billing_test_before_call, fn _operation, _args ->
        refute Repo.in_transaction?()
      end)

      event_id = "evt_" <> Ecto.UUID.generate()

      try do
        assert :ok =
                 Billing.record_and_apply_event(event_id, "subscription.created", %{
                   "event_type" => "subscription.created",
                   "data" => subscription
                 })

        assert {:ok, closed} = Accounts.close_account(state.account.id, "Leaving", state.subject)
        assert closed.deleted_at
        assert mirror(state.account).status == "canceled"
      after
        event_id |> List.wrap() |> ProcessedEvent.Query.by_ids() |> Repo.delete_all()
      end
    end)
  end

  test "the final URL check refuses an account disabled after provider confirmation", %{
    store: store
  } do
    unboxed_account(store, fn state ->
      parent = self()

      after_call = fn
        :bind, _args, result ->
          send(parent, {:bound, self()})

          receive do
            :continue_binding -> result
          end

        _operation, _args, result ->
          result
      end

      worker = checkout_task(state, fn _operation, _args -> :ok end, after_call)

      try do
        assert_receive {:bound, worker_pid}, 5_000
        Fixtures.Accounts.disable_account(state.account)
        send(worker_pid, :continue_binding)
        assert Task.await(worker, 10_000) == {:error, :checkout_pending}
        refute current_intent(state.account).state == :payable
      after
        stop_tasks([worker])
      end
    end)
  end

  test "two first-seen preparations of the same subscription never retire the canonical", %{
    store: store
  } do
    unboxed_account(store, fn state ->
      transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      subscription = Fixtures.Billing.complete_transaction(transaction["id"])
      parent = self()
      subscription_id = subscription["id"]

      after_call = fn
        :get_subscription, ^subscription_id, result ->
          send(parent, {:candidate_proved, self()})

          receive do
            :continue_candidate -> result
          end

        _operation, _args, result ->
          result
      end

      worker =
        unboxed_task(fn ->
          configure_provider(state.store, fn _operation, _args -> :ok end, after_call)

          deliver_event(
            %{
              "event_type" => "subscription.created",
              "data" => subscription
            },
            state.account
          )
        end)

      try do
        assert_receive {:candidate_proved, worker_pid}, 5_000

        assert :ok =
                 deliver_event(
                   %{
                     "event_type" => "subscription.created",
                     "data" => subscription
                   },
                   state.account
                 )

        send(worker_pid, :continue_candidate)
        assert :ok = Task.await(worker, 10_000)
        assert mirror(state.account).paddle_subscription_id == subscription_id
        assert is_nil(SubscriptionRetirements.find(subscription_id))
        refute_received {:paddle, :cancel_subscription, _id, _caller}
      after
        stop_tasks([worker])
      end
    end)
  end

  defp checkout_task(state, before_call, after_call) do
    unboxed_task(fn ->
      configure_provider(state.store, before_call, after_call)
      Billing.start_checkout(state.account, "team", :month, state.subject)
    end)
  end

  test "a known old-ID receipt cannot overwrite a replacement committed while it waits", %{
    store: store
  } do
    unboxed_account(store, fn state ->
      transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      old = Fixtures.Billing.complete_transaction(transaction["id"], %{"status" => "canceled"})
      assert :ok = deliver_event(subscription_event(old), state.account)
      next_transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      replacement = Fixtures.Billing.complete_transaction(next_transaction["id"])
      parent = self()

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            assert {:ok, _account} = Accounts.fetch_and_lock_account(state.account.id)
            send(parent, {:holding_account, self(), backend_pid()})

            receive do
              :replace ->
                # Unsigned authenticated no-conflict adoption remains supported.
                deliver_event(
                  subscription_event(Map.delete(replacement, "custom_data")),
                  state.account
                )
            end
          end)
        end)

      assert_receive {:holding_account, holder_pid, holder_backend}, 5_000

      receipt =
        unboxed_task(fn ->
          configure_provider(state.store, fn _, _ -> :ok end, fn _, _, result -> result end)
          send(parent, {:receipt_backend, backend_pid()})
          deliver_event(subscription_event(Map.put(old, "status", "active")), state.account)
        end)

      try do
        assert_receive {:receipt_backend, receipt_backend}, 5_000
        await_blocked_by(receipt_backend, holder_backend)
        send(holder_pid, :replace)
        assert {:ok, :ok} = Task.await(holder, 10_000)
        assert Task.await(receipt, 10_000) == {:error, {:apply_failed, :stale_reconciliation}}
        assert mirror(state.account).paddle_subscription_id == replacement["id"]
        assert mirror(state.account).status == "active"
        assert is_nil(SubscriptionRetirements.find(replacement["id"]))
      after
        stop_tasks([holder, receipt])
      end
    end)
  end

  test "final closure refuses checkout or retirement work committed at its account lock", %{
    store: store
  } do
    for work <- [:checkout, :retirement] do
      unboxed_account(store, fn state ->
        transaction = Fixtures.Billing.create_legacy_transaction(state.account)
        subscription = Fixtures.Billing.complete_transaction(transaction["id"])
        parent = self()

        holder =
          unboxed_task(fn ->
            configure_provider(state.store, fn _, _ -> :ok end, fn _, _, result -> result end)

            Repo.transaction(fn ->
              assert {:ok, _account} = Accounts.fetch_and_lock_account(state.account.id)
              send(parent, {:holding_account, self(), backend_pid()})

              receive do
                :insert_work ->
                  case work do
                    :checkout -> Fixtures.Billing.create_checkout_intent(state.account)
                    :retirement -> Fixtures.Billing.create_retirement(state.account, subscription)
                  end
              end
            end)
          end)

        assert_receive {:holding_account, holder_pid, holder_backend}, 5_000

        closer =
          unboxed_task(fn ->
            configure_provider(state.store, fn _, _ -> refute Repo.in_transaction?() end, fn _,
                                                                                             _,
                                                                                             result ->
              result
            end)

            send(parent, {:closer_backend, backend_pid()})
            Accounts.close_account(state.account.id, "Leaving", state.subject)
          end)

        try do
          assert_receive {:closer_backend, closer_backend}, 5_000
          await_blocked_by(closer_backend, holder_backend)
          send(holder_pid, :insert_work)
          assert {:ok, _row} = Task.await(holder, 10_000)

          reason =
            if work == :checkout, do: :checkout_pending, else: :subscription_retirement_pending

          assert Task.await(closer, 10_000) == {:error, {:paddle_cancel_failed, reason}}
          assert is_nil(Repo.reload!(state.account).deleted_at)
          refute_received {:paddle, :cancel_subscription, _id, _caller}
        after
          stop_tasks([holder, closer])
        end
      end)
    end
  end

  test "payment racing unpaid cancellation reconciles before closure can finish", %{store: store} do
    unboxed_account(store, fn state ->
      assert {:ok, _url} = Billing.start_checkout(state.account, "team", :month, state.subject)
      intent = current_intent(state.account)

      Config.put_override(:emisar, :billing_test_before_call, fn
        :cancel_transaction, transaction_id ->
          Fixtures.Billing.complete_transaction(transaction_id)

        _operation, _args ->
          :ok
      end)

      assert {:error, {:paddle_cancel_failed, :payment_reconciling}} =
               Accounts.close_account(state.account.id, "Leaving", state.subject)

      assert is_nil(Repo.reload!(state.account).deleted_at)
      Config.put_override(:emisar, :billing_test_before_call, fn _, _ -> :ok end)
      assert {:ok, closed} = Accounts.close_account(state.account.id, "Leaving", state.subject)
      assert closed.deleted_at
      assert Repo.reload!(intent).state == :subscribed
      assert mirror(state.account).status == "canceled"
      assert_received {:paddle, :create, _attrs, _caller}
      refute_received {:paddle, :create, _attrs, _caller}
    end)
  end

  test "provider-success DB failures in payable and canceled checkpoints recover without another old POST",
       %{
         store: store
       } do
    for transition <- [:payable, :canceled] do
      unboxed_account(store, fn state ->
        assert {:ok, _url} = Billing.start_checkout(state.account, "team", :month, state.subject)
        intent = current_intent(state.account)

        if transition == :payable do
          # Arrange the committed pre-URL checkpoint, retaining the real bound transaction.
          Fixtures.Billing.rewind_to_binding(intent)
        end

        constraint = "checkout_transition_" <> String.replace(Ecto.UUID.generate(), "-", "")

        Repo.query!(
          "ALTER TABLE billing_checkout_intents ADD CONSTRAINT #{constraint} CHECK (id != '#{intent.id}'::uuid OR state != '#{transition}')"
        )

        try do
          worker =
            unboxed_task(fn ->
              configure_provider(state.store, fn _, _ -> :ok end, fn _, _, result -> result end)
              cycle = if transition == :canceled, do: :year, else: :month

              try do
                Billing.start_checkout(state.account, "team", cycle, state.subject)
              rescue
                error in Ecto.ConstraintError -> {:raised, error.__struct__}
              end
            end)

          try do
            assert Task.await(worker, 10_000) == {:raised, Ecto.ConstraintError}
            assert_received {:paddle, :create, _attrs, _caller}
            refute_received {:paddle, :create, _attrs, _caller}
            assert {:ok, transaction} = Provider.retrieve_transaction(intent.transaction_id)

            assert transaction["status"] ==
                     if(transition == :canceled, do: "canceled", else: "ready")
          after
            stop_tasks([worker])
          end
        after
          Repo.query!(
            "ALTER TABLE billing_checkout_intents DROP CONSTRAINT IF EXISTS #{constraint}"
          )
        end

        cycle = if transition == :canceled, do: :year, else: :month
        assert {:ok, _url} = Billing.start_checkout(state.account, "team", cycle, state.subject)

        if transition == :payable do
          refute_received {:paddle, :create, _attrs, _caller}
        else
          assert_received {:paddle, :create, _attrs, _caller}
          refute_received {:paddle, :create, _attrs, _caller}
        end
      end)
    end
  end

  defp subscription_event(data), do: %{"event_type" => "subscription.created", "data" => data}

  defp deliver_event(event, account) do
    event_id = "evt_checkout_#{account.id}_#{Ecto.UUID.generate()}"
    Fixtures.Billing.deliver_event(event, event_id)
  end

  test "canonical cancellation survives provider success followed by failed DB persistence", %{
    store: store
  } do
    unboxed_account(store, fn state ->
      transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      subscription = Fixtures.Billing.complete_transaction(transaction["id"])
      assert :ok = deliver_event(subscription_event(subscription), state.account)
      canonical = mirror(state.account)
      constraint = "canonical_cancel_" <> String.replace(Ecto.UUID.generate(), "-", "")

      Repo.query!(
        "ALTER TABLE billing_subscriptions ADD CONSTRAINT #{constraint} CHECK (account_id != '#{state.account.id}'::uuid OR status != 'canceled')"
      )

      try do
        assert_raise Ecto.ConstraintError, fn ->
          Accounts.close_account(state.account.id, "Leaving", state.subject)
        end

        assert is_nil(Repo.reload!(state.account).deleted_at)
        assert Repo.reload!(canonical).status == "active"

        assert {:ok, %{"status" => "canceled"}} =
                 Provider.retrieve_subscription(subscription["id"])

        assert_received {:paddle, :cancel_subscription, _id, _caller}
        refute_received {:paddle, :cancel_subscription, _id, _caller}
      after
        Repo.query!("ALTER TABLE billing_subscriptions DROP CONSTRAINT IF EXISTS #{constraint}")
      end

      assert {:ok, closed} = Accounts.close_account(state.account.id, "Leaving", state.subject)
      assert closed.deleted_at
      assert Repo.reload!(canonical).status == "canceled"
      refute_received {:paddle, :cancel_subscription, _id, _caller}
    end)
  end

  test "a replacement during canonical cancellation is never stamped canceled or closed", %{
    store: store
  } do
    unboxed_account(store, fn state ->
      transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      original = Fixtures.Billing.complete_transaction(transaction["id"])
      assert :ok = deliver_event(subscription_event(original), state.account)
      next_transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      replacement = Fixtures.Billing.complete_transaction(next_transaction["id"])
      parent = self()

      after_call = fn
        :cancel_subscription, _id, result ->
          send(parent, {:canonical_canceled, self(), result})

          receive do
            :continue_close -> result
          end

        _, _, result ->
          result
      end

      closer =
        unboxed_task(fn ->
          configure_provider(state.store, fn _, _ -> :ok end, after_call)
          Accounts.close_account(state.account.id, "Leaving", state.subject)
        end)

      try do
        assert_receive {:canonical_canceled, closer_pid, {:ok, canceled}}, 5_000
        assert {:ok, _canceled} = Billing.reconcile_subscription_data(canceled)
        assert :ok = deliver_event(subscription_event(replacement), state.account)
        send(closer_pid, :continue_close)

        assert Task.await(closer, 10_000) ==
                 {:error, {:paddle_cancel_failed, :stale_reconciliation}}

        assert is_nil(Repo.reload!(state.account).deleted_at)
        assert mirror(state.account).paddle_subscription_id == replacement["id"]
        assert mirror(state.account).status == "active"
      after
        stop_tasks([closer])
      end
    end)
  end

  test "a returned different customer blocks canonical cancellation before its POST", %{
    store: store
  } do
    unboxed_account(store, fn state ->
      transaction = Fixtures.Billing.create_legacy_transaction(state.account)
      subscription = Fixtures.Billing.complete_transaction(transaction["id"])
      assert :ok = deliver_event(subscription_event(subscription), state.account)

      Fixtures.Billing.set_subscription(subscription["id"], %{"customer_id" => "ctm_someone_else"})

      assert {:error, {:paddle_cancel_failed, :cancellation_not_confirmed}} =
               Accounts.close_account(state.account.id, "Leaving", state.subject)

      assert is_nil(Repo.reload!(state.account).deleted_at)
      refute_received {:paddle, :cancel_subscription, _id, _caller}
    end)
  end

  defp configure_provider(store, before_call, after_call) do
    Config.put_override(:emisar, :paddle_client, Provider)
    Config.put_override(:emisar, :billing_test_provider, store)
    Config.put_override(:emisar, :billing_test_before_call, before_call)
    Config.put_override(:emisar, :billing_test_after_call, after_call)
  end

  defp unboxed_account(store, fun) do
    Sandbox.unboxed_run(Repo, fn ->
      user = Fixtures.Users.create_user()
      second_user = Fixtures.Users.create_user()

      account =
        Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_" <> Ecto.UUID.generate()})

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(user, account)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: second_user.id,
        role: "owner"
      )

      second_subject = Fixtures.Subjects.subject_for(second_user, account)

      try do
        fun.(%{account: account, subject: subject, second_subject: second_subject, store: store})
      after
        Fixtures.Billing.delete_checkout_test_receipts(account.id)
        Fixtures.Billing.delete_recovery_rows(account.id)
        Accounts.delete_by_id(account.id)
        Users.delete_by_id(user.id)
        Users.delete_by_id(second_user.id)
      end
    end)
  end

  defp current_intent(account) do
    account.id
    |> CheckoutIntent.Query.by_account_id()
    |> CheckoutIntent.Query.pending()
    |> Repo.peek()
  end

  defp mirror(account) do
    Subscription.Query.all() |> Subscription.Query.by_account_id(account.id) |> Repo.peek()
  end
end
