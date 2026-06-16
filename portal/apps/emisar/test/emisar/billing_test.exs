defmodule Emisar.BillingTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Billing
  alias Emisar.Billing.Subscription

  describe "plans/0" do
    test "has free, team, enterprise" do
      plans = Billing.plans()
      assert plans["free"].runners_limit == 3
      assert plans["team"].monthly_price_cents == 2000
      assert plans["enterprise"].runners_limit == :unlimited
    end
  end

  describe "account_plan/1 + sso_available?/1 — plan is derived from the subscription" do
    test "no subscription → free, SSO locked" do
      account = account_fixture()

      assert Billing.account_plan(account) == "free"
      refute Billing.sso_available?(account)
    end

    test "the subscription's plan is the account's plan" do
      account = account_fixture()
      subscription_fixture(account, "team")

      assert Billing.account_plan(account) == "team"
      # Team is not enterprise, so SSO stays locked.
      refute Billing.sso_available?(account)
    end

    test "an enterprise subscription unlocks SSO" do
      account = account_fixture()
      subscription_fixture(account, "enterprise")

      assert Billing.account_plan(account) == "enterprise"
      assert Billing.sso_available?(account)
    end

    test "status-agnostic: a canceled subscription still grants its plan" do
      # Billing status is advisory today — it informs (banners), it never
      # restricts — so a lapsed subscription keeps resolving to its plan
      # until status enforcement becomes a deliberate product decision.
      account = account_fixture()
      subscription_fixture(account, "enterprise", status: "canceled")

      assert Billing.account_plan(account) == "enterprise"
      assert Billing.sso_available?(account)
    end

    test "a webhook plan change is reflected immediately — the account row is never touched" do
      # Regression for the single-source fix: the Paddle webhook only ever
      # writes subscriptions.plan, so plan gating must read from there, not a
      # stale accounts.plan copy. Before this change a paid customer's account
      # stayed on "free" and SSO was wrongly unavailable.
      Application.put_env(:emisar, :paddle_price_ids, %{"enterprise" => "pri_ent_01"})
      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)

      account = account_fixture(%{paddle_customer_id: "ctm_upgrade_01"})
      refute Billing.sso_available?(account)

      event = subscription_created_event("evt_upgrade", account.paddle_customer_id, "pri_ent_01")
      assert :ok = Billing.record_and_apply_event("evt_upgrade", "subscription.created", event)

      # The SAME in-memory struct (never re-fetched) now resolves to
      # enterprise — proof the gate reads the subscription, not the account.
      assert Billing.account_plan(account) == "enterprise"
      assert Billing.sso_available?(account)
    end
  end

  describe "headroom/2" do
    test ":ok when more than one slot free" do
      assert Billing.headroom(%{runner_count: 1, runner_limit: 3}, :runners) == :ok
    end

    test ":warning when exactly one slot free" do
      assert Billing.headroom(%{runner_count: 2, runner_limit: 3}, :runners) == :warning
    end

    test ":at_limit when used == limit" do
      assert Billing.headroom(%{runner_count: 3, runner_limit: 3}, :runners) == :at_limit
    end

    test ":at_limit also when used > limit (operator deleted plan-tier-gated rows)" do
      assert Billing.headroom(%{runner_count: 5, runner_limit: 3}, :runners) == :at_limit
    end

    test ":unlimited bypasses everything" do
      assert Billing.headroom(%{runner_count: 100, runner_limit: :unlimited}, :runners) ==
               :unlimited
    end

    test "members uses the member_count/limit fields" do
      assert Billing.headroom(%{member_count: 0, member_limit: 1}, :members) == :warning
      assert Billing.headroom(%{member_count: 1, member_limit: 1}, :members) == :at_limit

      assert Billing.headroom(%{member_count: 5, member_limit: :unlimited}, :members) ==
               :unlimited
    end
  end

  describe "paddle client stub" do
    setup do
      Application.put_env(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Stub)
      :ok
    end

    test "create_customer returns a deterministic id for the same email" do
      {:ok, %{"id" => id1}} =
        Emisar.Billing.PaddleClient.create_customer(%{email: "a@example.com"})

      {:ok, %{"id" => id2}} =
        Emisar.Billing.PaddleClient.create_customer(%{email: "a@example.com"})

      assert id1 == id2
      assert String.starts_with?(id1, "ctm_stub_")
    end

    test "create_checkout_session returns a checkout URL" do
      {:ok, %{"url" => url}} =
        Emisar.Billing.PaddleClient.create_checkout_session(%{
          customer: "ctm_test",
          price_id: "pri_test"
        })

      assert String.starts_with?(url, "https://stub.paddle.test/checkout/")
    end

    test "construct_webhook_event parses JSON payloads" do
      payload = ~s({"event_type":"subscription.created","event_id":"evt_1"})

      {:ok, event} =
        Emisar.Billing.PaddleClient.construct_webhook_event(payload, "sig", "secret")

      assert event["event_type"] == "subscription.created"
    end
  end

  describe "open_billing_portal/2" do
    test "an account that never subscribed has no portal" do
      {_user, account, subject} = owner_subject_fixture()

      assert {:error, :no_customer} = Billing.open_billing_portal(account, subject)
    end

    test "returns the stub portal URL when no Paddle key is configured" do
      {_user, account, subject} = owner_subject_fixture()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:ok, url} = Billing.open_billing_portal(account, subject)
      assert url =~ "/app/settings/billing?status=stub-portal"
    end

    test "an owner of another account is refused" do
      {_user, account, _subject} = owner_subject_fixture()
      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:error, :unauthorized} = Billing.open_billing_portal(account, subject_b)
    end
  end

  describe "ensure_paddle_customer/2" do
    test "threads the acting user's email to Paddle on first creation" do
      # The test stub derives the customer id from the email it receives,
      # so two owners with different emails must yield different customer
      # ids. Before the fix (email: nil) both produced the same id.
      {_user_a, account_a, subject_a} =
        owner_subject_fixture(%{name: "Acct A"})

      {_user_b, account_b, subject_b} =
        owner_subject_fixture(%{name: "Acct B"})

      assert {:ok, cid_a, _} = Billing.ensure_paddle_customer(account_a, subject_a)
      assert {:ok, cid_b, _} = Billing.ensure_paddle_customer(account_b, subject_b)

      assert String.starts_with?(cid_a, "ctm_stub_")
      refute cid_a == cid_b
    end

    test "is idempotent — returns the existing customer id without re-creating" do
      {_user, account, subject} = owner_subject_fixture()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:ok, "ctm_existing_01", ^account} =
               Billing.ensure_paddle_customer(account, subject)
    end
  end

  describe "extract_next_billed_at/1" do
    test "parses ISO8601 from next_billed_at" do
      iso = "2026-07-01T00:00:00Z"

      assert %DateTime{year: 2026, month: 7, day: 1} =
               Billing.extract_next_billed_at(%{"next_billed_at" => iso})
    end

    test "falls back to current_billing_period.ends_at" do
      iso = "2026-08-15T12:34:56Z"

      assert %DateTime{year: 2026, month: 8, day: 15} =
               Billing.extract_next_billed_at(%{
                 "current_billing_period" => %{"ends_at" => iso}
               })
    end

    test "nil when neither field present" do
      assert Billing.extract_next_billed_at(%{}) == nil
    end
  end

  describe "record_and_apply_event/3 — subscription.created" do
    setup do
      # Map the team price id to the "team" plan, exactly as the webhook
      # payload nests it under items[].price.id (mirrors `:paddle_price_ids`).
      Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})
      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)
      :ok
    end

    test "persists a subscription with the plan derived from the price id" do
      account = account_fixture(%{paddle_customer_id: "ctm_team_01"})

      event =
        subscription_created_event("evt_created_1", account.paddle_customer_id, "pri_team_01")

      assert :ok = Billing.record_and_apply_event("evt_created_1", "subscription.created", event)

      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert subscription.plan == "team"
      assert subscription.status == "active"
      assert subscription.paddle_subscription_id == "sub_evt_created_1"
      assert subscription.paddle_price_id == "pri_team_01"
    end

    test "falls back to the account's current plan when the price id is unknown" do
      account = account_fixture(%{plan: "enterprise", paddle_customer_id: "ctm_ent_01"})

      # Enterprise is sales-led; no configured price id maps to it.
      event =
        subscription_created_event("evt_created_2", account.paddle_customer_id, "pri_unmapped")

      assert :ok = Billing.record_and_apply_event("evt_created_2", "subscription.created", event)

      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert subscription.plan == "enterprise"
    end

    test "no-op (still :ok) when no account matches the Paddle customer" do
      event = subscription_created_event("evt_created_3", "ctm_nobody", "pri_team_01")

      assert :ok = Billing.record_and_apply_event("evt_created_3", "subscription.created", event)
    end
  end

  describe "record_and_apply_event/3 — dedup + rollback" do
    test "a second delivery of the same event id is a duplicate and does not re-apply" do
      account = account_fixture(%{paddle_customer_id: "ctm_dup_01"})
      event = subscription_created_event("evt_dup", account.paddle_customer_id, nil)

      assert :ok = Billing.record_and_apply_event("evt_dup", "subscription.created", event)

      assert {:duplicate, "evt_dup"} =
               Billing.record_and_apply_event("evt_dup", "subscription.created", event)
    end

    test "an apply failure rolls back the dedup row so redelivery reprocesses" do
      account = account_fixture(%{paddle_customer_id: "ctm_fail_01"})

      # A payload with no status fails `validate_required(:status)` inside
      # the same transaction — the apply returns {:error, changeset}. (An
      # UNKNOWN status string deliberately persists — Paddle owns the value
      # space — so a missing field is the failure mode to exercise here.)
      bad_event =
        subscription_created_event("evt_fail", account.paddle_customer_id, nil)
        |> put_in(["data", "status"], nil)

      assert {:error, {:apply_failed, %Ecto.Changeset{}}} =
               Billing.record_and_apply_event("evt_fail", "subscription.created", bad_event)

      # The dedup row MUST be absent — otherwise Paddle's retry is swallowed.
      refute processed_event?("evt_fail")

      # No subscription leaked from the rolled-back transaction either.
      assert Subscription.Query.all()
             |> Subscription.Query.by_account_id(account.id)
             |> Repo.one() == nil

      # Redelivery with a now-valid payload reprocesses and persists.
      good_event = subscription_created_event("evt_fail", account.paddle_customer_id, nil)
      assert :ok = Billing.record_and_apply_event("evt_fail", "subscription.created", good_event)
      assert processed_event?("evt_fail")
    end
  end

  # A minimal Paddle subscription.created webhook envelope. The price id is
  # nested under data.items[].price.id, matching Paddle's Billing API.
  defp subscription_created_event(event_id, customer_id, price_id) do
    %{
      "event_id" => event_id,
      "event_type" => "subscription.created",
      "data" => %{
        "id" => "sub_" <> event_id,
        "customer_id" => customer_id,
        "status" => "active",
        "next_billed_at" => "2026-07-01T00:00:00Z",
        "items" => [%{"price" => %{"id" => price_id}}]
      }
    }
  end

  describe "billing_summary/2" do
    test "rolls plan limits + live counts + subscription mirror into one map" do
      {_user, account, subject} = owner_subject_fixture()
      _ = runner_fixture(account_id: account.id)

      assert {:ok, summary} = Billing.billing_summary(account, subject)
      assert summary.plan == "free"
      assert summary.runner_count == 1
      assert summary.runner_limit == 3
      assert summary.member_count == 1
      # Free plan is priced at 0, so the total is 0 — and the
      # never-subscribed mirror fields read nil.
      assert summary.monthly_total_cents == 0
      refute summary.subscription_status
      refute summary.current_period_end
    end

    test "an owner of account B cannot read account A's summary (cross-account)" do
      {_user_a, account_a, _subject_a} = owner_subject_fixture()
      {_user_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :unauthorized} = Billing.billing_summary(account_a, subject_b)
    end
  end

  describe "start_checkout/3" do
    test "rejects a plan name we do not sell" do
      {_user, account, subject} = owner_subject_fixture()

      assert {:error, :unknown_plan} = Billing.start_checkout(account, "platinum", subject)
    end

    test "returns the stub checkout URL when no Paddle price id is configured" do
      {_user, account, subject} = owner_subject_fixture()

      assert {:ok, "/paddle-checkout-stub?plan=team"} =
               Billing.start_checkout(account, "team", subject)
    end

    test "an admin (manage_billing is owner-only) is refused with :unauthorized" do
      {_user, account, _subject} = owner_subject_fixture()
      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      admin_subject = subject_for(admin, account, role: :admin)

      assert {:error, :unauthorized} = Billing.start_checkout(account, "team", admin_subject)
      assert {:error, :unauthorized} = Billing.open_billing_portal(account, admin_subject)
    end
  end

  describe "apply_webhook_event/1 subscription.canceled" do
    test "flips the mirrored status, and an unknown subscription id is a no-op" do
      {_user, account, _subject} = owner_subject_fixture()

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_live_1",
          plan: "team",
          status: "active"
        })

      assert {:ok, _} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.canceled",
                 "data" => %{"id" => "sub_live_1"}
               })

      assert %Subscription{status: "canceled"} =
               Repo.one(from(s in Subscription, where: s.account_id == ^account.id))

      assert :ok =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.canceled",
                 "data" => %{"id" => "sub_never_seen"}
               })
    end
  end

  describe "ensure_paddle_customer/2 first-wins" do
    test "a stale struct cannot clobber an already-linked customer id" do
      {_user, account, subject} = owner_subject_fixture()

      {:ok, first_customer_id, linked} = Billing.ensure_paddle_customer(account, subject)
      assert linked.paddle_customer_id == first_customer_id

      # Simulate the race: a second checkout still holds the pre-link
      # snapshot (nil customer id) and a DIFFERENT acting user, so the
      # stub would mint a different vendor customer. The locked row wins.
      other_owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: other_owner.id, role: "owner")
      other_subject = subject_for(other_owner, account, role: :owner)
      stale_account = %{account | paddle_customer_id: nil}

      assert {:ok, ^first_customer_id, relinked} =
               Billing.ensure_paddle_customer(stale_account, other_subject)

      assert relinked.paddle_customer_id == first_customer_id
    end
  end

  defp processed_event?(event_id) do
    Repo.exists?(from e in "paddle_processed_events", where: e.id == ^event_id)
  end
end
