defmodule Emisar.BillingAuditReceiptsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Billing, Fixtures}

  test "scheduling, rescheduling, and clearing retain both sides, including explicit nulls" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.create_subscription(account, "team")
    scheduled_at = DateTime.add(DateTime.utc_now(), 86_400, :second)
    rescheduled_at = DateTime.add(scheduled_at, 86_400, :second)

    assert {:ok, _} =
             Billing.upsert_subscription(account.id, %{
               scheduled_change_action: "cancel",
               scheduled_change_effective_at: scheduled_at
             })

    assert {:ok, _} =
             Billing.upsert_subscription(account.id, %{
               scheduled_change_effective_at: rescheduled_at
             })

    # Omission is not a clear, and an unchanged subscription is not a new event.
    assert {:ok, _} = Billing.upsert_subscription(account.id, %{status: "active"})

    clear = %{scheduled_change_action: nil, scheduled_change_effective_at: nil}
    assert {:ok, _} = Billing.upsert_subscription(account.id, clear)
    assert {:ok, _} = Billing.upsert_subscription(account.id, clear)

    assert [_created, scheduled, rescheduled, cleared] = events(account)

    assert scheduled.payload["from_scheduled_change_action"] == nil
    assert Map.has_key?(scheduled.payload, "from_scheduled_change_action")
    assert scheduled.payload["to_scheduled_change_action"] == "cancel"

    assert scheduled.payload["to_scheduled_change_effective_at"] ==
             DateTime.to_iso8601(scheduled_at)

    assert rescheduled.payload["from_scheduled_change_effective_at"] ==
             DateTime.to_iso8601(scheduled_at)

    assert rescheduled.payload["to_scheduled_change_effective_at"] ==
             DateTime.to_iso8601(rescheduled_at)

    assert rescheduled.payload["from_scheduled_change_action"] == "cancel"
    assert rescheduled.payload["to_scheduled_change_action"] == "cancel"
    assert cleared.payload["from_scheduled_change_action"] == "cancel"

    assert cleared.payload["from_scheduled_change_effective_at"] ==
             DateTime.to_iso8601(rescheduled_at)

    for field <- ~w[to_scheduled_change_action to_scheduled_change_effective_at] do
      assert Map.has_key?(cleared.payload, field)
      assert cleared.payload[field] == nil
    end

    assert cleared.payload["from_state"] == "ending"
    assert cleared.payload["to_state"] == "active"
  end

  test "legacy cancellation fields use the same effective schedule as entitlement checks" do
    account = Fixtures.Accounts.create_account()
    scheduled_at = DateTime.add(DateTime.utc_now(), 86_400, :second)
    rescheduled_at = DateTime.add(scheduled_at, 86_400, :second)

    Fixtures.Accounts.create_subscription(account, "team",
      cancel_at_period_end: true,
      current_period_end: scheduled_at
    )

    assert {:ok, rescheduled} =
             Billing.upsert_subscription(account.id, %{current_period_end: rescheduled_at})

    assert Billing.entitlement_state(rescheduled) == :ending

    assert {:ok, cleared} =
             Billing.upsert_subscription(account.id, %{cancel_at_period_end: false})

    assert Billing.entitlement_state(cleared) == :active
    assert [_created, changed, removed] = events(account)
    assert changed.payload["from_scheduled_change_action"] == "cancel"
    assert changed.payload["to_scheduled_change_action"] == "cancel"

    assert changed.payload["from_scheduled_change_effective_at"] ==
             DateTime.to_iso8601(scheduled_at)

    assert changed.payload["to_scheduled_change_effective_at"] ==
             DateTime.to_iso8601(rescheduled_at)

    assert removed.payload["to_scheduled_change_action"] == nil
    assert removed.payload["to_scheduled_change_effective_at"] == nil
  end

  test "canonical schedule facts take precedence over legacy cancellation fields" do
    account = Fixtures.Accounts.create_account()
    canonical_at = DateTime.add(DateTime.utc_now(), 172_800, :second)
    legacy_at = DateTime.add(canonical_at, 86_400, :second)

    Fixtures.Accounts.create_subscription(account, "team",
      scheduled_change_action: "pause",
      scheduled_change_effective_at: canonical_at,
      cancel_at_period_end: true,
      current_period_end: legacy_at
    )

    assert [created] = events(account)
    assert created.payload["to_scheduled_change_action"] == "pause"

    assert created.payload["to_scheduled_change_effective_at"] ==
             DateTime.to_iso8601(canonical_at)

    assert {:ok, _} =
             Billing.upsert_subscription(account.id, %{
               current_period_end: DateTime.add(legacy_at, 86_400, :second)
             })

    assert [same_event] = events(account)
    assert same_event.id == created.id
  end

  test "a status-only change records the actual transition without claiming a plan change" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.create_subscription(account, "team", collection_mode: "automatic")
    assert {:ok, _} = Billing.upsert_subscription(account.id, %{status: "past_due"})
    assert [_created, changed] = events(account)

    assert changed.payload["from"] == "team"
    assert changed.payload["to"] == "team"
    assert changed.payload["from_status"] == "active"
    assert changed.payload["to_status"] == "past_due"
    assert changed.payload["from_state"] == "active"
    assert changed.payload["to_state"] == "dunning"
  end

  test "a stored plan change remains visible when paid access is already expired" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.create_subscription(account, "team", status: "canceled")
    assert {:ok, _} = Billing.upsert_subscription(account.id, %{plan: "enterprise"})
    assert [_created, changed] = events(account)

    assert changed.payload["from"] == "free"
    assert changed.payload["to"] == "free"
    assert changed.payload["from_subscribed_plan"] == "team"
    assert changed.payload["to_subscribed_plan"] == "enterprise"
    assert changed.payload["from_status"] == "canceled"
    assert changed.payload["to_status"] == "canceled"
  end

  test "complimentary plan removal explicitly records the absent subscription status once" do
    account = Fixtures.Accounts.create_account()
    assert {:ok, _} = Billing.grant_complimentary_plan(account, "team")
    assert {:ok, _} = Billing.revoke_complimentary_plan(account)
    assert {:ok, :already_free} = Billing.revoke_complimentary_plan(account)
    assert [_granted, removed] = events(account)

    assert removed.payload["from_subscribed_plan"] == "team"
    assert removed.payload["to_subscribed_plan"] == "free"
    assert removed.payload["from_status"] == "complimentary"
    assert Map.has_key?(removed.payload, "to_status")
    assert removed.payload["to_status"] == nil
  end

  test "subscription mutations emit receipts only for their own account" do
    account = Fixtures.Accounts.create_account()
    other = Fixtures.Accounts.create_account()
    Fixtures.Accounts.create_subscription(account, "team")
    Fixtures.Accounts.create_subscription(other, "enterprise")
    assert [other_created] = events(other)

    assert {:ok, _} = Billing.upsert_subscription(account.id, %{status: "paused"})
    assert [_created, changed] = events(account)
    assert changed.account_id == account.id
    assert changed.target_id == account.id
    assert changed.actor_kind == "system"
    assert [untouched] = events(other)
    assert untouched.id == other_created.id
  end

  test "a rejected subscription update leaves no audit receipt" do
    account = Fixtures.Accounts.create_account()

    assert {:error, %Ecto.Changeset{}} =
             Billing.upsert_subscription(account.id, %{plan: "team", status: nil})

    assert events(account) == []
  end

  test "the builder retains supplied nulls but excludes unrecognized metadata" do
    account = Fixtures.Accounts.create_account()

    assert {:ok, event} =
             Audit.record(
               Audit.Events.subscription_changed(account.id, "free", "team",
                 from_status: nil,
                 to_status: "active",
                 to_scheduled_change_action: nil,
                 secret: "must not enter the audit payload"
               )
             )

    assert Repo.reload!(event).payload == %{
             "from" => "free",
             "to" => "team",
             "from_status" => nil,
             "to_status" => "active",
             "to_scheduled_change_action" => nil
           }
  end

  defp events(account) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account.id)
    |> Audit.Event.Query.by_event_type("subscription.changed")
    |> Audit.Event.Query.ordered_for_export()
    |> Repo.all()
  end
end
