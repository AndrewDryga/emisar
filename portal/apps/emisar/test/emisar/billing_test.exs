# A Paddle client whose vendor calls fail (or return a malformed shape), so
# the error paths the in-process Stub can't reach — a 5xx on checkout / customer
# creation / portal open — are exercisable. Swapped in per-test via
# `:paddle_client` and restored on exit.
defmodule Emisar.BillingTest.ErrorPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def create_customer(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def create_checkout_session(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  # A non-`{:ok, %{"url" => _}}` shape — the live API returning something we
  # don't model. `open_billing_portal/2` passes it through verbatim.
  def create_billing_portal_session(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def retrieve_subscription(_id), do: {:error, :paddle_unavailable}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :invalid_payload}
end

defmodule Emisar.BillingTest do
  use Emisar.DataCase, async: true
  alias Emisar.Auth.Subject
  alias Emisar.Billing
  alias Emisar.Billing.Subscription
  alias Emisar.BillingTest.ErrorPaddleClient
  alias Emisar.Fixtures

  describe "plans/0" do
    test "has free, team, enterprise" do
      plans = Billing.plans()
      assert plans["free"].runners_limit == 3
      assert plans["team"].monthly_price_cents == 2000
      assert plans["enterprise"].runners_limit == :unlimited
    end
  end

  describe "plan/1" do
    test "maps a known plan name to its definition" do
      # Each name resolves to the same map plans/0 exposes — the per-name accessor.
      assert Billing.plan("free") == Billing.plans()["free"]
      assert Billing.plan("team").monthly_price_cents == 2000
      assert Billing.plan("enterprise").runners_limit == :unlimited
    end

    test "an unknown plan name is nil (callers degrade it to free-tier limits)" do
      # A renamed/legacy plan name isn't in the map — plan/1 returns nil and the
      # callers (check_limit, billing_summary) fall back to plan("free").
      assert is_nil(Billing.plan("platinum"))
    end
  end

  describe "account_plan/1" do
    setup do
      %{account: Fixtures.Accounts.create_account()}
    end

    test "no subscription → free, SSO + directory sync locked", %{account: account} do
      assert Billing.account_plan(account) == "free"
      refute Billing.sso_available?(account)
      refute Billing.directory_sync_available?(account)
    end

    test "Team unlocks OIDC SSO but not SCIM directory sync", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "team")

      assert Billing.account_plan(account) == "team"
      assert Billing.sso_available?(account)
      # SCIM directory sync stays Enterprise-only.
      refute Billing.directory_sync_available?(account)
    end

    test "an enterprise subscription unlocks SSO + SCIM directory sync", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "enterprise")

      assert Billing.account_plan(account) == "enterprise"
      assert Billing.sso_available?(account)
      assert Billing.directory_sync_available?(account)
    end

    test "status-agnostic: a canceled subscription still grants its plan", %{account: account} do
      # Billing status is advisory today — it informs (banners), it never
      # restricts — so a lapsed subscription keeps resolving to its plan
      # until status enforcement becomes a deliberate product decision.
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

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

      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upgrade_01"})
      refute Billing.sso_available?(account)

      event = subscription_created_event("evt_upgrade", account.paddle_customer_id, "pri_ent_01")
      assert :ok = Billing.record_and_apply_event("evt_upgrade", "subscription.created", event)

      # The SAME in-memory struct (never re-fetched) now resolves to
      # enterprise — proof the gate reads the subscription, not the account.
      assert Billing.account_plan(account) == "enterprise"
      assert Billing.sso_available?(account)
    end
  end

  describe "account_audit_retention_days/1" do
    test "returns the account plan's audit-retention window" do
      free = Fixtures.Accounts.create_account()
      team = Fixtures.Accounts.create_account(plan: "team")
      enterprise = Fixtures.Accounts.create_account(plan: "enterprise")

      assert Billing.account_audit_retention_days(free.id) == 7
      assert Billing.account_audit_retention_days(team.id) == 90
      assert Billing.account_audit_retention_days(enterprise.id) == 365
    end

    test "falls back to the free window for an unknown/renamed plan" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "legacy-unlisted-plan")

      assert Billing.account_audit_retention_days(account.id) == 7
    end

    test "an audit_retention_days entitlement overrides the plan default" do
      account = Fixtures.Accounts.create_account()
      entitlements = %{"audit_retention_days" => 30}
      Fixtures.Accounts.create_subscription(account, "team", entitlements: entitlements)

      assert Billing.account_audit_retention_days(account.id) == 30
    end

    test "retention must stay a positive integer — \"unlimited\" or 0 falls back" do
      account = Fixtures.Accounts.create_account()
      entitlements = %{"audit_retention_days" => "unlimited"}
      Fixtures.Accounts.create_subscription(account, "team", entitlements: entitlements)

      assert Billing.account_audit_retention_days(account.id) == 90
    end
  end

  describe "sso_available?/1" do
    setup do
      %{account: Fixtures.Accounts.create_account()}
    end

    test "true on Team and Enterprise (both include OIDC SSO)", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "team")
      assert Billing.sso_available?(account)

      enterprise = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(enterprise, "enterprise")
      assert Billing.sso_available?(enterprise)
    end

    test "false on Free (never subscribed) — SSO is a paid feature", %{account: account} do
      refute Billing.sso_available?(account)
    end

    test "an sso entitlement overrides the plan gate in both directions", %{account: account} do
      # Withdrawn on Team by entitlement…
      Fixtures.Accounts.create_subscription(account, "team", entitlements: %{"sso" => false})
      refute Billing.sso_available?(account)

      # …and granted on a plan slug the compiled map doesn't know.
      custom = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(custom, "pro", entitlements: %{"sso" => true})
      assert Billing.sso_available?(custom)
    end
  end

  describe "directory_sync_available?/1" do
    setup do
      %{account: Fixtures.Accounts.create_account()}
    end

    test "true only on Enterprise (SCIM directory sync is Enterprise-only)", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "enterprise")
      assert Billing.directory_sync_available?(account)
    end

    test "false on Free and on Team (SCIM stays above Team)", %{account: account} do
      # Free (never subscribed) is locked…
      refute Billing.directory_sync_available?(account)

      # …and so is Team — SSO unlocks at Team but SCIM does not.
      team = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(team, "team")
      refute Billing.directory_sync_available?(team)
    end

    test "a scim entitlement unlocks directory sync below Enterprise", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "team", entitlements: %{"scim" => true})

      assert Billing.directory_sync_available?(account)
    end
  end

  describe "upsert_subscription/2 — unique_constraint backstop" do
    test "a concurrent first-insert loses on the per-account unique index" do
      # upsert_subscription peeks-then-inserts, so two callers that both peek-miss
      # would both try to INSERT for the same account. unique_index(:subscriptions,
      # [:account_id]) backstops the race: the second insert hits the constraint and
      # is mapped to an invalid changeset (Paddle's redelivery then takes the update
      # branch). Drive both inserts directly to exercise the constraint.
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Subscription{}} =
               Subscription.Changeset.upsert(%{
                 account_id: account.id,
                 plan: "team",
                 status: "active"
               })
               |> Repo.insert()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Subscription.Changeset.upsert(%{
                 account_id: account.id,
                 plan: "team",
                 status: "active"
               })
               |> Repo.insert()

      assert {"has already been taken", _} = changeset.errors[:account_id]
    end
  end

  describe "upsert_subscription/2 — partial reconciliation preserves untouched fields" do
    test "a status+period-only upsert leaves plan + cycle-note columns intact" do
      # The BillingSync worker upserts ONLY %{status, current_period_end} — exactly
      # the partial attr set the peek-then-update path is built for. The existing
      # row's plan/paddle_price_id/cancel_at_period_end/trial_end are keys ABSENT
      # from those attrs, so they survive (the documented "relies on existing plan"
      # write-gap: the sweep never refreshes plan/cycle fields).
      account = Fixtures.Accounts.create_account()

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_partial_recon",
          paddle_price_id: "pri_team_01",
          plan: "team",
          status: "active"
        })

      period_end = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second)

      assert {:ok, %Subscription{}} =
               Billing.upsert_subscription(account.id, %{
                 status: "past_due",
                 current_period_end: period_end
               })

      reloaded =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      # Only the two reconciled fields moved…
      assert reloaded.status == "past_due"
      assert %DateTime{} = reloaded.current_period_end
      # …plan + price + the cycle-note defaults are untouched (absent from the attrs).
      assert reloaded.plan == "team"
      assert reloaded.paddle_price_id == "pri_team_01"
      assert reloaded.cancel_at_period_end == false
      assert is_nil(reloaded.trial_end)
    end
  end

  describe "check_limit/2 — downgrade past current usage is not reconciled" do
    test "FINDING: existing over-cap runners keep running; only NEW ones are blocked" do
      # Downgrading below current usage (Team→Free here, via cancel) does NOT sweep
      # the excess runners — check_limit only gates the fresh-insert / re-enable
      # path. So an account that drops to a smaller cap keeps every already-counted
      # runner, and the NEXT register is what's refused. Assert the documented
      # un-reconciled state.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_downgrade_01"})

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_downgrade_01",
          plan: "team",
          status: "active"
        })

      # Five billable runners — fine under Team's 100 cap.
      for _ <- 1..5, do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      assert :ok = Billing.check_limit(account, :runners)

      # Cancel drops the entitlement back to free (cap 3). The five existing runners
      # are NOT touched — count is still 5, well over the new cap.
      assert {:ok, _} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.canceled",
                 "data" => %{"id" => "sub_downgrade_01"}
               })

      assert Emisar.Runners.count_billable_runners(account.id) == 5

      # account_plan is status-agnostic, so "team" still resolves even after cancel;
      # set the plan to free to model the real downgrade and prove the gate then
      # blocks only the NEXT runner while the over-cap five keep running.
      {:ok, _} = Billing.upsert_subscription(account.id, %{plan: "free", status: "canceled"})

      assert Billing.account_plan(account) == "free"
      assert {:error, :over_limit, "free", 3} = Billing.check_limit(account, :runners)
    end
  end

  describe "check_limit/2 — entitlements override the compiled plan limits" do
    test "a lower runners_limit entitlement blocks before the plan default would" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(account, "team",
        entitlements: %{"runners_limit" => 1}
      )

      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert Billing.check_limit(account, :runners) == {:error, :over_limit, "team", 1}
    end

    test "an \"unlimited\" entitlement lifts the plan cap" do
      account = Fixtures.Accounts.create_account()
      entitlements = %{"runners_limit" => "unlimited"}
      Fixtures.Accounts.create_subscription(account, "free", entitlements: entitlements)

      # Four billable runners — over free's compiled cap of 3.
      for _ <- 1..4, do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert Billing.check_limit(account, :runners) == :ok
    end
  end

  describe "start_checkout/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "rejects a plan name we do not sell", %{account: account, subject: subject} do
      assert {:error, :unknown_plan} = Billing.start_checkout(account, "platinum", subject)
    end

    test "returns the stub checkout URL when no Paddle price id is configured", %{
      account: account,
      subject: subject
    } do
      assert {:ok, "/paddle-checkout-stub?plan=team"} =
               Billing.start_checkout(account, "team", subject)
    end

    test "an admin (manage_billing is owner-only) is refused with :unauthorized", %{
      account: account
    } do
      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:error, :unauthorized} = Billing.start_checkout(account, "team", admin_subject)
      assert {:error, :unauthorized} = Billing.open_billing_portal(account, admin_subject)
    end

    test "the owner of another account is denied checkout AND portal for account A" do
      # Account-B's owner holds manage_billing on B, but ensure_subject_owns_account
      # binds the gate to the subject's own account — so acting on A is :unauthorized.
      {_user_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Billing.start_checkout(account_a, "team", subject_b)
      assert {:error, :unauthorized} = Billing.open_billing_portal(account_a, subject_b)
    end
  end

  describe "open_billing_portal/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "an account that never subscribed has no portal", %{account: account, subject: subject} do
      assert {:error, :no_customer} = Billing.open_billing_portal(account, subject)
    end

    test "returns the stub portal URL when no Paddle key is configured", %{
      account: account,
      subject: subject
    } do
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:ok, url} = Billing.open_billing_portal(account, subject)
      assert url =~ "/app/settings/billing?status=stub-portal"
    end

    test "an owner of another account is refused", %{account: account} do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
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
        Fixtures.Subjects.owner_subject(%{name: "Acct A"})

      {_user_b, account_b, subject_b} =
        Fixtures.Subjects.owner_subject(%{name: "Acct B"})

      assert {:ok, cid_a, _} = Billing.ensure_paddle_customer(account_a, subject_a)
      assert {:ok, cid_b, _} = Billing.ensure_paddle_customer(account_b, subject_b)

      assert String.starts_with?(cid_a, "ctm_stub_")
      refute cid_a == cid_b
    end

    test "is idempotent — returns the existing customer id without re-creating" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:ok, "ctm_existing_01", ^account} =
               Billing.ensure_paddle_customer(account, subject)
    end
  end

  describe "ensure_paddle_customer/2 — internal helper has no own Subject gate" do
    test "it takes a %Subject{} for its email only — authz is the start_checkout caller's" do
      # ensure_paddle_customer/2 runs NO ensure_has_permissions of its own: by
      # design the manage_billing gate lives in its caller (start_checkout/3), and
      # the helper just threads the acting user's email onto the Paddle customer.
      # The contract is arity-2 (account, subject) with no permission-bearing
      # arity-3 variant, and it succeeds for any owner subject without a gate of
      # its own. (start_checkout's gate is proven by the admin/cross-account
      # denial tests above.)
      assert function_exported?(Billing, :ensure_paddle_customer, 2)
      refute function_exported?(Billing, :ensure_paddle_customer, 3)

      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, customer_id, _account} = Billing.ensure_paddle_customer(account, subject)
      assert String.starts_with?(customer_id, "ctm_stub_")
    end
  end

  describe "ensure_paddle_customer/2 first-wins" do
    test "a stale struct cannot clobber an already-linked customer id" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, first_customer_id, linked} = Billing.ensure_paddle_customer(account, subject)
      assert linked.paddle_customer_id == first_customer_id

      # Simulate the race: a second checkout still holds the pre-link
      # snapshot (nil customer id) and a DIFFERENT acting user, so the
      # stub would mint a different vendor customer. The locked row wins.
      other_owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: other_owner.id,
          role: "owner"
        )

      other_subject = Fixtures.Subjects.subject_for(other_owner, account, role: :owner)
      stale_account = %{account | paddle_customer_id: nil}

      assert {:ok, ^first_customer_id, relinked} =
               Billing.ensure_paddle_customer(stale_account, other_subject)

      assert relinked.paddle_customer_id == first_customer_id
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

  describe "record_and_apply_event/3 — subscription.created" do
    setup do
      # Map the team price id to the "team" plan, exactly as the webhook
      # payload nests it under items[].price.id (mirrors `:paddle_price_ids`).
      Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})
      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)
      :ok
    end

    test "persists a subscription with the plan derived from the price id" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_team_01"})

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

    test "mirrors product custom_data into entitlements and takes the plan from its slug" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_ent_01"})

      # The price id is deliberately NOT in :paddle_price_ids — the product's
      # own custom_data identifies the plan, no deployed mapping needed.
      event =
        subscription_created_event("evt_ent_1", account.paddle_customer_id, "pri_unmapped_99",
          product_custom_data: %{
            "plan" => "team",
            "runners_limit" => "25",
            "members_limit" => "unlimited",
            "sso" => "true",
            "typo_key" => "dropped"
          }
        )

      assert :ok = Billing.record_and_apply_event("evt_ent_1", "subscription.created", event)

      subscription = Repo.one(Subscription)
      assert subscription.plan == "team"

      assert subscription.entitlements == %{
               "runners_limit" => 25,
               "members_limit" => "unlimited",
               "sso" => true
             }
    end

    test "a plan change writes a subscription.changed AUDIT row (distinct from the Mixpanel event)" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_audit_01"})

      event = subscription_created_event("evt_audit_1", account.paddle_customer_id, "pri_team_01")
      assert :ok = Billing.record_and_apply_event("evt_audit_1", "subscription.created", event)

      # free → team is a real plan transition → exactly one audit row, from/to,
      # system-actor, account-scoped.
      assert [audit] = Repo.all(Emisar.Audit.Event)
      assert audit.event_type == "subscription.changed"
      assert audit.account_id == account.id
      assert audit.actor_kind == "system"
      assert audit.payload["from"] == "free"
      assert audit.payload["to"] == "team"
    end

    test "emits [:emisar, :billing, :webhook] tagged by outcome (applied, then duplicate)" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_tel_01"})

      event =
        subscription_created_event("evt_tel_1", account.paddle_customer_id, "pri_team_01")

      handler = make_ref()
      test_pid = self()

      :telemetry.attach(
        handler,
        [:emisar, :billing, :webhook],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:billing_webhook, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = Billing.record_and_apply_event("evt_tel_1", "subscription.created", event)
      assert_receive {:billing_webhook, %{count: 1}, %{outcome: :applied}}

      # Paddle re-delivers the same event id → deduped.
      assert {:duplicate, _} =
               Billing.record_and_apply_event("evt_tel_1", "subscription.created", event)

      assert_receive {:billing_webhook, %{count: 1}, %{outcome: :duplicate}}
    end

    test "falls back to the account's current plan when the price id is unknown" do
      account =
        Fixtures.Accounts.create_account(%{plan: "enterprise", paddle_customer_id: "ctm_ent_01"})

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

    test "a created event with no scheduled cancel / billing-period / quantity leaves those columns at defaults" do
      # `upsert_from_subscription/1` now maps cancel_at_period_end / current_period_start
      # / quantity from the Paddle payload (see the scheduled-cancel test below), but a
      # plain subscription.created carrying none of those must leave them at their
      # defaults, not invent values. `trial_end` is not yet mapped (BACKLOG).
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_cyclenote_01"})

      event =
        subscription_created_event("evt_cyclenote", account.paddle_customer_id, "pri_team_01")

      assert :ok = Billing.record_and_apply_event("evt_cyclenote", "subscription.created", event)

      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      # `cancel_at_period_end` defaults to false at the DB level; the others are
      # nullable and never populated by the apply path.
      assert subscription.cancel_at_period_end == false
      assert is_nil(subscription.trial_end)
      assert is_nil(subscription.current_period_start)
    end

    test "a scheduled cancel + billing period + quantity land on the mirror (the cancel banner's source)" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_sched_cancel_01"})
      created = subscription_created_event("evt_sc", account.paddle_customer_id, "pri_team_01")
      assert :ok = Billing.record_and_apply_event("evt_sc", "subscription.created", created)

      updated = %{
        "event_id" => "evt_sc_upd",
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_evt_sc",
          "customer_id" => account.paddle_customer_id,
          "status" => "active",
          "scheduled_change" => %{"action" => "cancel", "effective_at" => "2026-09-01T00:00:00Z"},
          "current_billing_period" => %{
            "starts_at" => "2026-08-01T00:00:00Z",
            "ends_at" => "2026-09-01T00:00:00Z"
          },
          "items" => [%{"price" => %{"id" => "pri_team_01"}, "quantity" => 5}]
        }
      }

      assert :ok = Billing.record_and_apply_event("evt_sc_upd", "subscription.updated", updated)

      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert subscription.cancel_at_period_end == true
      # access-until = the scheduled cancel's effective_at, not next_billed_at
      assert %DateTime{year: 2026, month: 9, day: 1} = subscription.current_period_end
      assert %DateTime{year: 2026, month: 8, day: 1} = subscription.current_period_start
      assert subscription.quantity == 5
    end

    test "current_period_end is extracted through the apply path from either source" do
      # The apply path (not just extract_next_billed_at/1 in isolation) populates
      # current_period_end. Paddle puts the next charge under `next_billed_at` OR
      # `current_billing_period.ends_at` — both must land on the mirror row.
      top_level = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_period_top_01"})

      # The created envelope carries `next_billed_at` (top-level source).
      top_event =
        subscription_created_event("evt_period_top", top_level.paddle_customer_id, "pri_team_01")

      assert :ok =
               Billing.record_and_apply_event("evt_period_top", "subscription.created", top_event)

      assert %Subscription{current_period_end: %DateTime{year: 2026, month: 7, day: 1}} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(top_level.id)
               |> Repo.one()

      # A payload with ONLY current_billing_period.ends_at (no next_billed_at) —
      # the nested fallback source the apply path also reads.
      nested = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_period_nested_01"})

      nested_event = %{
        "event_type" => "subscription.created",
        "data" => %{
          "id" => "sub_period_nested",
          "customer_id" => nested.paddle_customer_id,
          "status" => "active",
          "current_billing_period" => %{"ends_at" => "2026-08-15T12:34:56Z"},
          "items" => [%{"price" => %{"id" => "pri_team_01"}}]
        }
      }

      assert {:ok, _} = Billing.apply_webhook_event(nested_event)

      assert %Subscription{current_period_end: %DateTime{year: 2026, month: 8, day: 15}} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(nested.id)
               |> Repo.one()
    end

    test "an out-of-order event (older Paddle updated_at) is dropped, not applied over fresher state" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_ooo_01"})
      created = subscription_created_event("evt_ooo", account.paddle_customer_id, "pri_team_01")
      assert :ok = Billing.record_and_apply_event("evt_ooo", "subscription.created", created)

      # A fresh active update stamps the row's monotonic paddle_updated_at = T2.
      fresh = %{
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_evt_ooo",
          "customer_id" => account.paddle_customer_id,
          "status" => "active",
          "updated_at" => "2026-08-15T00:00:00Z",
          "items" => [%{"price" => %{"id" => "pri_team_01"}}]
        }
      }

      assert :ok = Billing.record_and_apply_event("evt_ooo_fresh", "subscription.updated", fresh)

      # A late cancel that OCCURRED EARLIER (updated_at T1 < T2) must be dropped,
      # not clobber the row to canceled.
      stale_cancel = %{
        "event_type" => "subscription.canceled",
        "data" => %{"id" => "sub_evt_ooo", "updated_at" => "2026-08-10T00:00:00Z"}
      }

      assert :ok =
               Billing.record_and_apply_event(
                 "evt_ooo_stale",
                 "subscription.canceled",
                 stale_cancel
               )

      assert %Subscription{status: "active"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()

      # A cancel that OCCURRED LATER (updated_at T3 > T2) applies — the guard
      # drops only stale events, never fresher ones.
      newer_cancel = %{
        "event_type" => "subscription.canceled",
        "data" => %{"id" => "sub_evt_ooo", "updated_at" => "2026-08-20T00:00:00Z"}
      }

      assert :ok =
               Billing.record_and_apply_event(
                 "evt_ooo_newer",
                 "subscription.canceled",
                 newer_cancel
               )

      assert %Subscription{status: "canceled"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end
  end

  describe "record_and_apply_event/3 — dedup + apply commit atomically" do
    setup do
      Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})
      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)
      :ok
    end

    test "on success the dedup row AND the subscription mutation commit together" do
      # The dedup insert and apply run in ONE Multi (record_and_apply_event), so a
      # successful delivery leaves BOTH the processed-events row AND the mirror row
      # — never a half state. (The failure-rollback companion is asserted in the
      # "dedup + rollback" describe: a failed apply leaves NEITHER.)
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_atomic_01"})
      event = subscription_created_event("evt_atomic", account.paddle_customer_id, "pri_team_01")

      assert :ok = Billing.record_and_apply_event("evt_atomic", "subscription.created", event)

      assert processed_event?("evt_atomic")

      assert %Subscription{plan: "team", paddle_subscription_id: "sub_evt_atomic"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end
  end

  describe "record_and_apply_event/3 — unhandled event type" do
    test "a well-formed unmodeled event_type is a no-op that still commits the dedup row" do
      # `apply_webhook_event(_event), do: :ok` catches any type we don't model.
      # The apply succeeds (no DB write, no account resolve), so the dedup row
      # DOES commit — distinct from the apply-failure rollback path (asserted by
      # the next describe block: a failure leaves NO processed-events row).
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_unhandled_01"})

      event = %{
        "event_id" => "evt_unhandled",
        "event_type" => "transaction.completed",
        "data" => %{"id" => "txn_01", "customer_id" => account.paddle_customer_id}
      }

      assert :ok =
               Billing.record_and_apply_event("evt_unhandled", "transaction.completed", event)

      # No subscription written by the no-op.
      assert Subscription.Query.all()
             |> Subscription.Query.by_account_id(account.id)
             |> Repo.one() == nil

      # The dedup row committed (the no-op is a success), so a redelivery dedups.
      assert processed_event?("evt_unhandled")

      assert {:duplicate, "evt_unhandled"} =
               Billing.record_and_apply_event("evt_unhandled", "transaction.completed", event)
    end

    test "a brand-new, never-seen future Paddle event type is a no-op (forward-compatible)" do
      # The total `apply_webhook_event(_event)` clause cannot fail, so an event
      # type this code has never seen (a future Paddle addition) is accepted as a
      # no-op rather than 500-ing — forward-compatible by construction. No account
      # resolve, no subscription write; the dedup row still commits.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_future_01"})

      event = %{
        "event_id" => "evt_future",
        "event_type" => "subscription.future_capability_2099",
        "data" => %{"id" => "sub_future", "customer_id" => account.paddle_customer_id}
      }

      assert :ok =
               Billing.record_and_apply_event(
                 "evt_future",
                 "subscription.future_capability_2099",
                 event
               )

      assert Subscription.Query.all()
             |> Subscription.Query.by_account_id(account.id)
             |> Repo.one() == nil

      assert processed_event?("evt_future")
    end
  end

  describe "record_and_apply_event/3 — dedup + rollback" do
    test "a second delivery of the same event id is a duplicate and does not re-apply" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_dup_01"})
      event = subscription_created_event("evt_dup", account.paddle_customer_id, nil)

      assert :ok = Billing.record_and_apply_event("evt_dup", "subscription.created", event)

      assert {:duplicate, "evt_dup"} =
               Billing.record_and_apply_event("evt_dup", "subscription.created", event)
    end

    test "an apply failure rolls back the dedup row so redelivery reprocesses" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_fail_01"})

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

  describe "apply_webhook_event/1 — subscription.updated" do
    setup do
      # Two plans mapped so an update can move a row from team → enterprise.
      Application.put_env(:emisar, :paddle_price_ids, %{
        "team" => "pri_team_01",
        "enterprise" => "pri_ent_01"
      })

      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)
      :ok
    end

    test "re-derives the plan on the existing row (no new row inserted)" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_plan_01"})

      created =
        subscription_created_event("evt_upd_plan_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, %Subscription{plan: "team"}} = Billing.apply_webhook_event(created)

      # Same subscription id, a price that now maps to enterprise.
      updated =
        subscription_updated_event(
          "evt_upd_plan_c",
          account.paddle_customer_id,
          "pri_ent_01",
          status: "active"
        )

      assert {:ok, %Subscription{plan: "enterprise"}} = Billing.apply_webhook_event(updated)

      # The plan moved on the SAME row — exactly one subscription for the account.
      subscriptions =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.all()

      assert [%Subscription{plan: "enterprise", status: "active"}] = subscriptions
    end

    test "an update without a product object preserves stored entitlements" do
      # subscription_updated_event carries no product — put_present skips the
      # absent entitlements rather than nulling the mirror.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_ent_keep_01"})

      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_ent_keep",
        entitlements: %{"runners_limit" => 25}
      )

      updated =
        subscription_updated_event("ent_keep", account.paddle_customer_id, "pri_team_01",
          status: "past_due"
        )

      assert {:ok, _} = Billing.apply_webhook_event(updated)

      subscription = Repo.one(Subscription)
      assert subscription.status == "past_due"
      assert subscription.entitlements == %{"runners_limit" => 25}
    end

    test "a payload re-stating its fields preserves plan + price + period" do
      # The peek-then-update path (not a null-clobbering on_conflict) keeps the
      # plan resolved via account_plan/1 even when the price id is unmapped, and
      # a full payload that re-sends items + next_billed_at carries price/period
      # through. Paddle sends the FULL subscription object on subscription.updated,
      # so this is the realistic shape. (A truly items-less payload is a separate,
      # narrower case asserted below — the apply path preserves those columns.)
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_full_01"})

      created =
        subscription_created_event("evt_upd_full_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, _} = Billing.apply_webhook_event(created)

      before =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert before.plan == "team"
      assert before.paddle_price_id == "pri_team_01"
      assert before.current_period_end

      # A status transition that re-sends the same items/next_billed_at.
      updated =
        subscription_updated_event("evt_upd_full_c", account.paddle_customer_id, "pri_team_01",
          status: "past_due"
        )

      assert {:ok, %Subscription{}} = Billing.apply_webhook_event(updated)

      after_update =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert after_update.status == "past_due"
      assert after_update.plan == "team"
      assert after_update.paddle_price_id == "pri_team_01"
      # next_billed_at moved (the updated envelope carries a later date), proving
      # the field was rewritten, not dropped.
      assert after_update.current_period_end
    end

    test "an items-less partial payload preserves paddle_price_id + current_period_end" do
      # (the partial-payload half)
      # A status-only `subscription.updated` (no `items` / `next_billed_at`) must
      # NOT null price/period: `upsert_from_subscription/1` omits those keys when
      # the payload doesn't carry them, so the peek-then-update preserves the
      # stored values. `plan` is preserved via the account_plan/1 fallback.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_partial_01"})

      created =
        subscription_created_event("evt_upd_partial_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, _} = Billing.apply_webhook_event(created)

      before =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      # Status-only payload: no items, no next_billed_at.
      partial = %{
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_evt_upd_partial_c",
          "customer_id" => account.paddle_customer_id,
          "status" => "past_due"
        }
      }

      assert {:ok, %Subscription{}} = Billing.apply_webhook_event(partial)

      after_update =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert after_update.status == "past_due"
      assert after_update.plan == "team"
      # price + period are preserved, not clobbered by the partial payload.
      assert after_update.paddle_price_id == before.paddle_price_id
      assert after_update.current_period_end == before.current_period_end
    end

    test "an unknown/foreign customer is a no-op (no write, still :ok)" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_known_01"})

      created =
        subscription_created_event("evt_upd_known_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, _} = Billing.apply_webhook_event(created)

      # An update whose customer_id matches no account resolves to nil → :ok no-op.
      foreign =
        subscription_updated_event("evt_upd_foreign", "ctm_nobody_at_all", "pri_ent_01",
          status: "active"
        )

      assert :ok = Billing.apply_webhook_event(foreign)

      # The real account's row is untouched (still team).
      assert %Subscription{plan: "team"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end

    test "an update for an account with no prior mirror takes the insert branch" do
      # upsert_subscription/2 peeks for an existing row; with none, a
      # subscription.updated inserts (the same clause as subscription.created),
      # so a first-seen update still lands the mirror rather than no-opping.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_noprior_01"})

      # No created event first — the very first event is an `updated`.
      updated =
        subscription_updated_event("evt_upd_noprior", account.paddle_customer_id, "pri_ent_01",
          status: "active"
        )

      assert {:ok, %Subscription{}} = Billing.apply_webhook_event(updated)

      assert [%Subscription{plan: "enterprise", status: "active"}] =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.all()
    end

    test "an unmapped price id on update falls back to the account's current plan" do
      # plan_for_subscription/2 can't resolve an unmapped price id, so it falls
      # back to account_plan/1 — the existing subscription's plan. A sales-led
      # price the map doesn't carry keeps the row on its current (team) plan.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_unmapped_01"})

      created =
        subscription_created_event(
          "evt_upd_unmapped_c",
          account.paddle_customer_id,
          "pri_team_01"
        )

      assert {:ok, %Subscription{plan: "team"}} = Billing.apply_webhook_event(created)

      updated =
        subscription_updated_event(
          "evt_upd_unmapped_c",
          account.paddle_customer_id,
          "pri_not_in_map",
          status: "active"
        )

      assert {:ok, %Subscription{}} = Billing.apply_webhook_event(updated)

      # Plan held at team (the account's current plan); price mirrors the new id.
      assert %Subscription{plan: "team", paddle_price_id: "pri_not_in_map"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end

    test "an unmodeled status on update persists (no inclusion list, no 500)" do
      # status is an open :string — Paddle owns the value space — so a status this
      # code has never seen still persists rather than failing the changeset and
      # 500-ing the webhook on every redelivery.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_unseen_01"})

      created =
        subscription_created_event("evt_upd_unseen_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, _} = Billing.apply_webhook_event(created)

      updated =
        subscription_updated_event("evt_upd_unseen_c", account.paddle_customer_id, "pri_team_01",
          status: "some_new_paddle_status"
        )

      assert {:ok, %Subscription{status: "some_new_paddle_status"}} =
               Billing.apply_webhook_event(updated)
    end
  end

  describe "apply_webhook_event/1 — subscription.updated rollback + ordering" do
    setup do
      Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})
      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)
      :ok
    end

    test "a missing status on an update fails the apply and rolls the dedup row back" do
      # An update lacking `status` fails `validate_required([..., :status])` exactly
      # as a created does (the upsert changeset is shared), so the apply returns
      # {:error, changeset}, record_and_apply_event rolls the dedup row back, and
      # Paddle's redelivery reprocesses rather than being swallowed.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_nostatus_01"})

      created =
        subscription_created_event(
          "evt_upd_nostatus_c",
          account.paddle_customer_id,
          "pri_team_01"
        )

      assert {:ok, _} = Billing.apply_webhook_event(created)

      bad_update =
        subscription_updated_event(
          "evt_upd_nostatus_c",
          account.paddle_customer_id,
          "pri_team_01",
          status: "active"
        )
        |> put_in(["data", "status"], nil)

      assert {:error, {:apply_failed, %Ecto.Changeset{}}} =
               Billing.record_and_apply_event(
                 "evt_upd_nostatus_apply",
                 "subscription.updated",
                 bad_update
               )

      # The dedup row was rolled back with the failed apply…
      refute processed_event?("evt_upd_nostatus_apply")

      # …and the prior row is untouched: still active (the failed update never landed).
      assert %Subscription{status: "active"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end

    test "FINDING: a stale out-of-order update clobbers a newer state (last-writer-wins)" do
      # There is no version/sequence guard in upsert_from_subscription — every
      # field the payload carries is written. So replaying an OLDER captured
      # `subscription.updated` AFTER a newer one rewinds the row to the stale
      # state. Assert the documented stale-clobber risk so a future ordering
      # guard is a deliberate change, not an accidental regression.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_stale_01"})

      created =
        subscription_created_event("evt_upd_stale_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, _} = Billing.apply_webhook_event(created)

      # The newer state arrives first: past_due.
      newer =
        subscription_updated_event("evt_upd_stale_c", account.paddle_customer_id, "pri_team_01",
          status: "past_due"
        )

      assert {:ok, %Subscription{status: "past_due"}} = Billing.apply_webhook_event(newer)

      # A stale capture (a DIFFERENT event id, so dedup doesn't block it) replays
      # an older "active" state — and wins, because nothing compares timestamps.
      stale = %{
        "event_id" => "evt_upd_stale_old",
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_evt_upd_stale_c",
          "customer_id" => account.paddle_customer_id,
          "status" => "active",
          "items" => [%{"price" => %{"id" => "pri_team_01"}}]
        }
      }

      assert {:ok, %Subscription{status: "active"}} = Billing.apply_webhook_event(stale)

      # The row was rewound to the stale status — the documented last-writer-wins.
      assert %Subscription{status: "active"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end
  end

  describe "apply_webhook_event/1 — Subject-less; audits the plan change" do
    setup do
      Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})
      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)
      :ok
    end

    test "applying a subscription event takes no %Subject{} — the signature is the edge auth" do
      # apply_webhook_event/1 and record_and_apply_event/3 are the webhook entry
      # points; they carry NO per-account authorization because the BILL-005
      # signature verify at the HTTP edge is the only auth. The contract is the
      # arity: a 1-arg apply and a 3-arg record_and_apply, neither taking a Subject.
      assert function_exported?(Billing, :apply_webhook_event, 1)
      refute function_exported?(Billing, :apply_webhook_event, 2)
      assert function_exported?(Billing, :record_and_apply_event, 3)

      # And it actually applies with no subject in scope.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_nosubj_01"})
      event = subscription_created_event("evt_nosubj", account.paddle_customer_id, "pri_team_01")

      assert {:ok, %Subscription{plan: "team"}} = Billing.apply_webhook_event(event)
    end

    test "a plan change writes a subscription.changed audit row (the trail is no longer blind)" do
      # Was the documented gap: the apply path used to write only the subscriptions
      # mirror, so a plan change left no audit trace (a downgrade-to-wipe with no
      # evidence). It now emits `subscription.changed` from the write chokepoint.
      # (Fixtures.Accounts.create_account writes no audit rows, so this isolates the
      # apply's own emission.)
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_noaudit_01"})
      event = subscription_created_event("evt_noaudit", account.paddle_customer_id, "pri_team_01")

      assert {:ok, %Subscription{}} = Billing.apply_webhook_event(event)

      assert [audit] =
               Emisar.Audit.Event.Query.all()
               |> Emisar.Audit.Event.Query.by_account_id(account.id)
               |> Repo.all()

      assert audit.event_type == "subscription.changed"
      assert audit.payload["from"] == "free"
      assert audit.payload["to"] == "team"
    end
  end

  describe "apply_webhook_event/1 — subscription.canceled keeps entitlement" do
    test "a canceled subscription still resolves to its plan (advisory-only status)" do
      # Cancel writes ONLY status: "canceled"; account_plan/1 is status-agnostic,
      # so the plan/limits are unchanged and a runner under the (Team) cap still
      # registers. Status is an advisory banner, never an entitlement gate.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_cancel_ent_01"})

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_cancel_ent_01",
          plan: "team",
          status: "active"
        })

      assert {:ok, %Subscription{status: "canceled"}} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.canceled",
                 "data" => %{"id" => "sub_cancel_ent_01"}
               })

      # Entitlement untouched: still Team, still well under the 100-runner cap.
      assert Billing.account_plan(account) == "team"
      assert :ok = Billing.check_limit(account, :runners)
    end

    test "the cancel's partial %{status} satisfies validate_required via the stored row" do
      # Cancel applies `Subscription.Changeset.upsert(existing, %{status: "canceled"})`
      # — only `status` is cast. validate_required([:account_id, :plan, :status]) is
      # still satisfied because account_id + plan come from the EXISTING struct's
      # loaded fields, so the one-field update commits (and would NOT on a bare
      # %Subscription{} with no plan — which is why the on-miss branch no-ops).
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_cancel_partial_01"})

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_cancel_partial_01",
          plan: "team",
          status: "active"
        })

      assert {:ok, %Subscription{status: "canceled", plan: "team", account_id: account_id}} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.canceled",
                 "data" => %{"id" => "sub_cancel_partial_01"}
               })

      assert account_id == account.id
    end
  end

  describe "apply_webhook_event/1 — subscription.updated status transition" do
    setup do
      Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})
      on_exit(fn -> Application.delete_env(:emisar, :paddle_price_ids) end)
      :ok
    end

    test "a status-only transition rewrites status on the existing row" do
      # An update re-sending the same price/items but a new status rewrites
      # status on the same mirror row (peek-then-update), plan unchanged.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_status_01"})

      created =
        subscription_created_event("evt_upd_status_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, %Subscription{status: "active"}} = Billing.apply_webhook_event(created)

      updated =
        subscription_updated_event("evt_upd_status_c", account.paddle_customer_id, "pri_team_01",
          status: "past_due"
        )

      assert {:ok, %Subscription{status: "past_due", plan: "team"}} =
               Billing.apply_webhook_event(updated)
    end
  end

  describe "apply_webhook_event/1 — unmodeled subscription event types" do
    test "pause/resume/trialing are unhandled no-ops that leave the mirror untouched" do
      # emisar does NOT mirror subscription.paused/resumed/trialing — they hit
      # the catch-all `apply_webhook_event(_event), do: :ok`. The existing row's
      # status is preserved (those banner statuses only arise via a
      # subscription.updated payload, which IS modeled).
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_unmodeled_01"})

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_unmodeled_01",
          plan: "team",
          status: "active"
        })

      for event_type <- ["subscription.paused", "subscription.resumed", "subscription.trialing"] do
        assert :ok =
                 Billing.apply_webhook_event(%{
                   "event_type" => event_type,
                   "data" => %{
                     "id" => "sub_unmodeled_01",
                     "customer_id" => account.paddle_customer_id,
                     "status" => "paused"
                   }
                 })
      end

      # The mirror still reads its pre-event status — none of the three wrote.
      assert %Subscription{status: "active"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end
  end

  describe "apply_webhook_event/1 subscription.canceled" do
    test "flips the mirrored status, and an unknown subscription id is a no-op" do
      {_user, account, _subject} = Fixtures.Subjects.owner_subject()

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

  # A minimal Paddle subscription.created webhook envelope. The price id is
  # nested under data.items[].price.id, matching Paddle's Billing API.
  defp subscription_created_event(event_id, customer_id, price_id, opts \\ []) do
    item = %{"price" => %{"id" => price_id}}

    # Paddle embeds the full product per item; `product_custom_data:` models
    # the entitlement contract (plan slug + limits on the product).
    item =
      case opts[:product_custom_data] do
        nil ->
          item

        custom_data ->
          Map.put(item, "product", %{"id" => "pro_test_01", "custom_data" => custom_data})
      end

    %{
      "event_id" => event_id,
      "event_type" => "subscription.created",
      "data" => %{
        "id" => "sub_" <> event_id,
        "customer_id" => customer_id,
        "status" => "active",
        "next_billed_at" => "2026-07-01T00:00:00Z",
        "items" => [item]
      }
    }
  end

  # A subscription.updated envelope re-applied onto (usually) an existing row.
  # The `id` reuses the created event's `sub_<event_id>` so updates land on the
  # same mirror; pass `status:` to drive a status transition.
  defp subscription_updated_event(event_id, customer_id, price_id, opts) do
    %{
      "event_id" => "evt_upd_" <> event_id,
      "event_type" => "subscription.updated",
      "data" => %{
        "id" => "sub_" <> event_id,
        "customer_id" => customer_id,
        "status" => Keyword.fetch!(opts, :status),
        "next_billed_at" => "2026-09-01T00:00:00Z",
        "items" => [%{"price" => %{"id" => price_id}}]
      }
    }
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

  describe "extract_paddle_updated_at/1" do
    test "parses ISO8601 from updated_at (the monotonic stale-update guard's input)" do
      assert %DateTime{year: 2026, month: 8, day: 15, hour: 12} =
               Billing.extract_paddle_updated_at(%{"updated_at" => "2026-08-15T12:34:56Z"})
    end

    test "nil when updated_at is absent" do
      assert Billing.extract_paddle_updated_at(%{}) == nil
    end

    test "nil on a malformed updated_at (parse failure degrades, never raises)" do
      assert Billing.extract_paddle_updated_at(%{"updated_at" => "not-a-date"}) == nil
    end
  end

  describe "billing_summary/2" do
    test "rolls plan limits + live counts + subscription mirror into one map" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Runners.create_runner(account_id: account.id)

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

    test "entitlement limits surface in the summary instead of the compiled plan defaults" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      entitlements = %{
        "runners_limit" => 250,
        "members_limit" => 10,
        "audit_retention_days" => 180
      }

      Fixtures.Accounts.create_subscription(account, "team", entitlements: entitlements)

      assert {:ok, summary} = Billing.billing_summary(account, subject)
      assert summary.runner_limit == 250
      assert summary.member_limit == 10
      assert summary.audit_retention_days == 180
    end

    test "an unknown plan slug shows its capitalized name and no self-serve price" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      Fixtures.Accounts.create_subscription(account, "pro",
        entitlements: %{"runners_limit" => 50}
      )

      assert {:ok, summary} = Billing.billing_summary(account, subject)
      assert summary.plan == "pro"
      assert summary.plan_name == "Pro"
      assert summary.runner_limit == 50
      # Free-floor fallback for the fields no entitlement covers…
      assert summary.member_limit == 1
      # …and nil pricing (custom), never the free plan's $0.
      refute summary.monthly_per_runner_cents
      refute summary.monthly_total_cents
    end

    test "an owner of account B cannot read account A's summary (cross-account)" do
      {_user_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Billing.billing_summary(account_a, subject_b)
    end
  end

  describe "billing_summary/2 — view_billing role matrix" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "owner, admin, operator and viewer can all read the billing summary", %{
      account: account,
      subject: owner_subject
    } do
      # view_billing_permission is held by owner/admin/operator/viewer
      # (authorizer.ex:10-19), so every human role can read the dashboard.
      for role <- [:admin, :operator, :viewer] do
        member = Fixtures.Users.create_user()

        _ =
          Fixtures.Memberships.create_membership(
            account_id: account.id,
            user_id: member.id,
            role: to_string(role)
          )

        member_subject = Fixtures.Subjects.subject_for(member, account, role: role)

        assert {:ok, %{plan: "free"}} = Billing.billing_summary(account, member_subject)
      end

      assert {:ok, %{plan: "free"}} = Billing.billing_summary(account, owner_subject)
    end

    test "an api_client and a runner subject are denied the billing summary", %{account: account} do
      # Neither api_client nor runner appears in list_permissions_for_role, so
      # view_billing is absent and the read is refused.
      {_raw, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Subject.for_api_key(api_key, account)
      assert {:error, :unauthorized} = Billing.billing_summary(account, api_subject)

      runner = Fixtures.Runners.create_runner(account_id: account.id)
      runner_subject = Subject.for_runner(runner, account)
      assert {:error, :unauthorized} = Billing.billing_summary(account, runner_subject)
    end
  end

  describe "subject_can_manage_billing?/1" do
    setup do
      {_user, account, owner_subject} = Fixtures.Subjects.owner_subject()
      %{account: account, owner_subject: owner_subject}
    end

    test "true for an owner (manage_billing is owner-only)", %{owner_subject: owner_subject} do
      assert Billing.subject_can_manage_billing?(owner_subject)
    end

    test "false for admin, operator and viewer (they hold view, not manage)", %{account: account} do
      # The UI calls this to show/hide the checkout + portal controls — only the
      # owner role grants manage_billing, so every other human role is false.
      for role <- [:admin, :operator, :viewer] do
        member = Fixtures.Users.create_user()

        _ =
          Fixtures.Memberships.create_membership(
            account_id: account.id,
            user_id: member.id,
            role: to_string(role)
          )

        member_subject = Fixtures.Subjects.subject_for(member, account, role: role)

        refute Billing.subject_can_manage_billing?(member_subject)
      end
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

  defp processed_event?(event_id) do
    Repo.exists?(from e in "paddle_processed_events", where: e.id == ^event_id)
  end
end

defmodule Emisar.BillingVendorErrorTest do
  @moduledoc """
  The Paddle error paths the in-process Stub can't reach — a 5xx on checkout /
  customer creation / portal open. These swap `:paddle_client` to a failing
  client via `Application.put_env` (process-global), so this module is
  `async: false`: a concurrent async test calling the Paddle client (e.g.
  `Workers.BillingSync`) must not observe the failing client mid-run.
  """
  use Emisar.DataCase, async: false
  alias Emisar.Billing
  alias Emisar.BillingTest.ErrorPaddleClient
  alias Emisar.Fixtures

  setup do
    prev_client = Application.get_env(:emisar, :paddle_client)
    Application.put_env(:emisar, :paddle_client, ErrorPaddleClient)
    on_exit(fn -> restore(:paddle_client, prev_client) end)
    :ok
  end

  describe "start_checkout/3 — vendor failures" do
    setup do
      # A configured price id forces the real Paddle call path (not the
      # stub-URL short-circuit), so the failing client's error surfaces.
      prev_prices = Application.get_env(:emisar, :paddle_price_ids)
      Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})
      on_exit(fn -> restore(:paddle_price_ids, prev_prices) end)
      :ok
    end

    test "a vendor error on checkout-session creation bubbles up" do
      # An already-linked customer skips create_customer, so the only failing
      # call is create_checkout_session — its {:error, term} propagates out of
      # start_checkout unchanged (the LV turns it into a flash, no redirect).
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:error, :paddle_unavailable} = Billing.start_checkout(account, "team", subject)
    end

    test "a vendor error creating the customer short-circuits before any checkout" do
      # ensure_paddle_customer/2 runs first; when create_customer errors, the
      # `with` in start_checkout bails on it — no checkout session is attempted
      # and no customer id is ever persisted.
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      refute account.paddle_customer_id

      assert {:error, :paddle_unavailable} = Billing.start_checkout(account, "team", subject)

      # The failed create left no customer linked on the account row.
      assert {:ok, reloaded} = Emisar.Accounts.fetch_account_by_id(account.id)
      refute reloaded.paddle_customer_id
    end
  end

  describe "ensure_paddle_customer/2 — vendor failure" do
    test "a create_customer error returns {:error, term} and links nothing" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert {:error, :paddle_unavailable} = Billing.ensure_paddle_customer(account, subject)

      assert {:ok, reloaded} = Emisar.Accounts.fetch_account_by_id(account.id)
      refute reloaded.paddle_customer_id
    end
  end

  describe "open_billing_portal/2 — odd vendor shape" do
    setup do
      # With a Paddle API key set, open_billing_portal hits the live client
      # instead of the stub-URL fallback; the failing client returns a
      # non-{:ok, %{"url" => _}} shape that the function passes through verbatim.
      prev_key = Application.get_env(:emisar, :paddle_api_key)
      Application.put_env(:emisar, :paddle_api_key, "pdl_test_key")
      on_exit(fn -> restore(:paddle_api_key, prev_key) end)
      :ok
    end

    test "a non-url portal-session result is passed through, not crashed" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:error, :paddle_unavailable} = Billing.open_billing_portal(account, subject)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:emisar, key)
  defp restore(key, value), do: Application.put_env(:emisar, key, value)
end

# A Paddle client that captures the attrs each call receives by sending them to
# a registered test pid, then returns a successful shape — so the args
# `start_checkout/3` / `ensure_paddle_customer/2` build (per-seat quantity,
# success/cancel URLs, the verbatim email + name) can be asserted without the
# live HTTP layer.
defmodule Emisar.BillingTest.CapturingPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  # The capturing pid rides in app env (set per-test) so the client stays
  # stateless — the same pattern BillingSyncTest's fail-id client uses.
  defp report(message), do: send(Application.fetch_env!(:emisar, :billing_capture_pid), message)

  @impl true
  def create_customer(attrs) do
    report({:create_customer, attrs})
    {:ok, %{"id" => "ctm_captured_01"}}
  end

  @impl true
  def create_checkout_session(attrs) do
    report({:create_checkout_session, attrs})
    {:ok, %{"url" => "https://stub.paddle.test/checkout/captured"}}
  end

  @impl true
  def create_billing_portal_session(attrs) do
    report({:create_billing_portal_session, attrs})
    {:ok, %{"url" => "https://stub.paddle.test/portal/captured"}}
  end

  @impl true
  def retrieve_subscription(_id), do: {:error, :unused}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.BillingCheckoutArgsTest do
  @moduledoc """
  The exact args `start_checkout/3` + `ensure_paddle_customer/2` hand to the
  Paddle client — per-seat quantity, the success/cancel return URLs, and the
  verbatim email/name. Swaps the process-global `:paddle_client` (and registers
  a capture pid the client reports to), so `async: false`.
  """
  use Emisar.DataCase, async: false
  import ExUnit.CaptureLog
  alias Emisar.Billing
  alias Emisar.BillingTest.CapturingPaddleClient
  alias Emisar.Fixtures

  setup do
    prev_client = Application.get_env(:emisar, :paddle_client)
    prev_prices = Application.get_env(:emisar, :paddle_price_ids)

    Application.put_env(:emisar, :paddle_client, CapturingPaddleClient)
    Application.put_env(:emisar, :billing_capture_pid, self())
    # A configured price id forces the real client path (not the stub-URL
    # short-circuit), so the captured args are the ones a live checkout sends.
    Application.put_env(:emisar, :paddle_price_ids, %{"team" => "pri_team_01"})

    on_exit(fn ->
      restore(:paddle_client, prev_client)
      restore(:paddle_price_ids, prev_prices)
      Application.delete_env(:emisar, :billing_capture_pid)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:emisar, key)
  defp restore(key, value), do: Application.put_env(:emisar, key, value)

  test "the checkout quantity equals the account's live billable runner count" do
    # Team is per-runner pricing, so start_checkout passes
    # `quantity: current_count(account, :runners)` — the live billable count. Five
    # runners → quantity 5 on the created checkout session.
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_seat_count_01"}
    for _ <- 1..5, do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

    assert {:ok, _url} = Billing.start_checkout(account, "team", subject)

    assert_received {:create_checkout_session, %{quantity: 5, price_id: "pri_team_01"}}
  end

  test "FINDING: the success/cancel URLs are non-account-scoped /app/settings/billing" do
    # The checkout session is created with success/cancel URLs that point at the
    # bare `/app/settings/billing`, NOT the real account-scoped
    # `/app/:account/settings/billing`. Assert the documented redirect-target
    # mismatch (whether Paddle's post-checkout return resolves it is UNVERIFIED).
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_urls_01"}

    assert {:ok, _url} = Billing.start_checkout(account, "team", subject)

    assert_received {:create_checkout_session,
                     %{success_url: success_url, cancel_url: cancel_url}}

    assert success_url =~ "/app/settings/billing?status=success"
    assert cancel_url =~ "/app/settings/billing?status=cancelled"
    # The account slug never appears — the documented mismatch.
    refute success_url =~ account.slug
    refute cancel_url =~ account.slug
  end

  test "create_customer forwards the acting email + account name verbatim" do
    # ensure_paddle_customer threads the subject's email + the account name (incl.
    # special characters) straight onto the Paddle customer with no mangling —
    # invoices reach a real inbox and the customer is recognisable in Paddle.
    user = Fixtures.Users.create_user(%{email: "billing-owner@example.test"})
    {_u, account, subject} = Fixtures.Subjects.owner_subject(%{name: "Acme & Co. (Ops)"})
    # Re-bind the subject to the known-email user as owner of the account.
    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = %{subject | actor: user}

    assert {:ok, "ctm_captured_01", _account} = Billing.ensure_paddle_customer(account, subject)

    assert_received {:create_customer, attrs}
    assert attrs.email == "billing-owner@example.test"
    assert attrs.name == "Acme & Co. (Ops)"
    assert attrs.account_id == account.id
  end

  test "a normal checkout leaks no secret / customer id / price id into the log drain" do
    # The happy checkout + portal-open paths emit no log line carrying the Paddle
    # API key, the customer id, or the price id — those would land in the drain
    # (Sentry/console) verbatim. Capture the log around both and assert the
    # sensitive values never appear.
    prev_key = Application.get_env(:emisar, :paddle_api_key)
    Application.put_env(:emisar, :paddle_api_key, "pdl_live_secret_key")
    on_exit(fn -> restore(:paddle_api_key, prev_key) end)

    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_logsafe_01"}

    log =
      capture_log(fn ->
        assert {:ok, _} = Billing.start_checkout(account, "team", subject)
        assert {:ok, _} = Billing.open_billing_portal(account, subject)
      end)

    refute log =~ "pdl_live_secret_key"
    refute log =~ "ctm_logsafe_01"
    refute log =~ "pri_team_01"
  end
end
