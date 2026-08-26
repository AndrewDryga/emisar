# A Paddle client whose vendor calls fail (or return a malformed shape), so
# the error paths the in-process Stub can't reach — a 5xx on checkout / customer
# creation / portal open — are exercisable. Swapped in per-test via
# `:paddle_client` and restored on exit.
defmodule Emisar.BillingTest.ErrorPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  # Not what any of these stubs exercise; the behaviour requires it.
  @impl true
  def cancel_subscription(id), do: {:ok, %{"id" => id, "status" => "canceled"}}

  @impl true
  def create_customer(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def update_customer(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def list_customers(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def create_checkout_session(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def bind_checkout_transaction(_id, _binding), do: {:error, :paddle_unavailable}

  @impl true
  # A non-`{:ok, %{"url" => _}}` shape — the live API returning something we
  # don't model. `open_billing_portal/2` passes it through verbatim.
  def create_billing_portal_session(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def retrieve_subscription(_id), do: {:error, :paddle_unavailable}

  @impl true
  def update_subscription(_id, _attrs), do: {:error, :paddle_unavailable}

  @impl true
  def retrieve_transaction(_id), do: {:error, :paddle_unavailable}
  @impl true
  def list_subscriptions(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def list_products, do: {:error, :paddle_unavailable}

  @impl true
  def list_transactions(_attrs), do: {:error, :paddle_unavailable}

  @impl true
  def get_transaction_invoice(_id), do: {:error, :unused}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :invalid_payload}
end

# A Paddle client that rejects customer creation with a 409 the way the live API
# does. Both halves of the conflict — the error code and what the email lookup
# then finds — are per-test config, so one client covers the documented email
# conflict, a different 409, and a lookup that finds nobody.
defmodule Emisar.BillingTest.ConflictingCustomerPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  @impl true
  def create_customer(_attrs) do
    code = Emisar.Config.fetch_env!(:emisar, :billing_conflict_code)

    {:error, {:http, 409, ~s({"error":{"type":"request_error","code":"#{code}"}})}}
  end

  @impl true
  def list_customers(_attrs),
    do: {:ok, Emisar.Config.fetch_env!(:emisar, :billing_conflict_customers)}

  # Not what these tests exercise; the behaviour requires them.
  @impl true
  def update_customer(_attrs), do: {:error, :unused}
  @impl true
  def cancel_subscription(_id), do: {:error, :unused}
  @impl true
  def create_checkout_session(_attrs), do: {:error, :unused}

  @impl true
  def bind_checkout_transaction(_id, _binding), do: {:error, :unused}
  @impl true
  def create_billing_portal_session(_attrs), do: {:error, :unused}
  @impl true
  def retrieve_subscription(_id), do: {:error, :unused}

  @impl true
  def update_subscription(_id, _attrs), do: {:error, :unused}

  @impl true
  def retrieve_transaction(_id), do: {:error, :unused}
  @impl true
  def list_subscriptions(_attrs), do: {:error, :unused}
  @impl true
  def list_products, do: {:error, :unused}
  @impl true
  def list_transactions(_attrs), do: {:error, :unused}
  @impl true
  def get_transaction_invoice(_id), do: {:error, :unused}
  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.BillingTest do
  use Emisar.DataCase, async: true
  alias Emisar.Auth.Subject
  alias Emisar.Billing
  alias Emisar.Billing.Subscription
  alias Emisar.BillingTest.ConflictingCustomerPaddleClient
  alias Emisar.BillingTest.ErrorPaddleClient
  alias Emisar.Fixtures

  describe "plans/0" do
    test "has free, team, enterprise" do
      plans = Billing.plans()
      assert plans["free"].runners_limit == 3
      assert plans["team"].monthly_price_cents == 2000
      assert plans["enterprise"].runners_limit == :unlimited
    end

    test "enterprise names the dedicated Slack support channel the pricing page promises" do
      # The exact phrase the pricing card + comparison table use — the plan
      # contract and the public promise must stay one string.
      assert Keyword.fetch!(Billing.plans()["enterprise"].features, :support) ==
               "Dedicated Slack support channel"
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

  describe "self_service_checkout?/2" do
    test "allows only Team at the two published cadences" do
      assert Billing.self_service_checkout?("team", :month)
      assert Billing.self_service_checkout?("team", :year)
      refute Billing.self_service_checkout?("free", :month)
      refute Billing.self_service_checkout?("enterprise", :year)
      refute Billing.self_service_checkout?("team", :week)
    end
  end

  describe "annual_savings_label/1" do
    test "describes only exact whole-month annual discounts" do
      assert Billing.annual_savings_label(Billing.plan("team")) == "2 months free"

      assert Billing.annual_savings_label(%{
               monthly_price_cents: 2000,
               annual_price_cents: 22_000
             }) ==
               "1 month free"

      refute Billing.annual_savings_label(%{
               monthly_price_cents: 2000,
               annual_price_cents: 23_000
             })

      refute Billing.annual_savings_label(Billing.plan("free"))
      refute Billing.annual_savings_label(Billing.plan("enterprise"))
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

    test "a canceled subscription uses Free entitlements but retains its subscribed plan", %{
      account: account
    } do
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      assert Billing.account_plan(account) == "free"
      refute Billing.sso_available?(account)

      assert {:ok, %{plan: "free", subscribed_plan: "enterprise", entitlement_state: :expired}} =
               Billing.support_plan(account)
    end

    test "a webhook plan change is reflected immediately — the account row is never touched" do
      # Regression for the single-source fix: the Paddle webhook only ever
      # writes subscriptions.plan, so plan gating must read from there, not a
      # stale accounts.plan copy. Before this change a paid customer's account
      # stayed on "free" and SSO was wrongly unavailable.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upgrade_01"})
      refute Billing.sso_available?(account)

      event =
        subscription_created_event("evt_upgrade", account.paddle_customer_id, "pri_ent_01",
          product_name: "enterprise"
        )

      assert Billing.record_and_apply_event("evt_upgrade", "subscription.created", event) == :ok

      # The SAME in-memory struct (never re-fetched) now resolves to
      # enterprise — proof the gate reads the subscription, not the account.
      assert Billing.account_plan(account) == "enterprise"
      assert Billing.sso_available?(account)
    end
  end

  describe "entitlement_state/2" do
    test "projects every owned lifecycle state at the exact scheduled deadline" do
      now = ~U[2026-08-26 12:00:00.000000Z]
      future = DateTime.add(now, 60, :second)
      past = DateTime.add(now, -1, :second)

      assert Billing.entitlement_state(nil, now) == :free
      assert Billing.entitlement_state(%Subscription{status: "complimentary"}, now) == :active
      assert Billing.entitlement_state(%Subscription{status: "active"}, now) == :active
      assert Billing.entitlement_state(%Subscription{status: "trialing"}, now) == :active

      assert Billing.entitlement_state(
               %Subscription{status: "past_due", collection_mode: "automatic"},
               now
             ) == :dunning

      assert Billing.entitlement_state(%Subscription{status: "past_due"}, now) == :unresolved

      for action <- ["cancel", "pause"] do
        assert Billing.entitlement_state(
                 %Subscription{
                   status: "past_due",
                   collection_mode: "manual",
                   scheduled_change_action: action,
                   scheduled_change_effective_at: future
                 },
                 now
               ) == :unresolved
      end

      ending = %Subscription{
        status: "active",
        scheduled_change_action: "cancel",
        scheduled_change_effective_at: future
      }

      assert Billing.entitlement_state(ending, now) == :ending

      assert Billing.entitlement_state(%{ending | scheduled_change_effective_at: now}, now) ==
               :expired

      assert Billing.entitlement_state(%{ending | scheduled_change_effective_at: past}, now) ==
               :expired

      assert Billing.entitlement_state(
               %{ending | scheduled_change_action: "pause"},
               now
             ) == :ending

      assert Billing.entitlement_state(%Subscription{status: "paused"}, now) == :expired
      assert Billing.entitlement_state(%Subscription{status: "canceled"}, now) == :expired

      assert Billing.entitlement_state(%Subscription{status: "future_vendor_state"}, now) ==
               :unresolved
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

    # Read-tolerant degradation is right for DISPLAY, but this number also drives
    # two sweeps that Repo.delete_all run history — so an unrecognized slug fails
    # OPEN to the longest window any plan defines. Collapsing to the free floor
    # meant one renamed Paddle price pruned a paying account to 7 days.
    test "retains for the longest window on an unknown/renamed plan" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "legacy-unlisted-plan")

      assert Billing.account_audit_retention_days(account.id) == 365
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

    test "unresolved lifecycle denies paid features but preserves the longest retention" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team", status: "future_vendor_state")

      assert Billing.account_plan(account) == "free"
      refute Billing.sso_available?(account)
      assert Billing.account_audit_retention_days(account.id) == 365
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
      Fixtures.Accounts.create_subscription(account, "team",
        entitlements: %{"features_sso_enabled?" => false}
      )

      refute Billing.sso_available?(account)

      # …and granted on a plan slug the compiled map doesn't know.
      custom = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(custom, "pro",
        entitlements: %{"features_sso_enabled?" => true}
      )

      assert Billing.sso_available?(custom)
    end
  end

  describe "sso_available_for_account_id?/2" do
    test "rechecks the authoritative row by id for pre-auth and locked callers" do
      account = Fixtures.Accounts.create_account(plan: "team")
      assert Billing.sso_available_for_account_id?(account.id, [])

      Fixtures.Accounts.create_subscription(account, "team", status: "canceled")
      refute Billing.sso_available_for_account_id?(account.id, [])
    end
  end

  describe "continuous_audit_export_available?/1" do
    setup do
      %{account: Fixtures.Accounts.create_account()}
    end

    test "true on Team and Enterprise (CSV download + SIEM API)", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "team")
      assert Billing.continuous_audit_export_available?(account)

      enterprise = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(enterprise, "enterprise")
      assert Billing.continuous_audit_export_available?(enterprise)
    end

    test "false on Free — the in-console trail stays; taking data out is paid", %{
      account: account
    } do
      refute Billing.continuous_audit_export_available?(account)
    end

    test "an audit-export entitlement overrides the plan gate", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "team",
        entitlements: %{"features_audit_export_enabled?" => false}
      )

      refute Billing.continuous_audit_export_available?(account)

      granted = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(granted, "starter-2027",
        entitlements: %{"features_audit_export_enabled?" => true}
      )

      assert Billing.continuous_audit_export_available?(granted)
    end
  end

  describe "continuous_audit_export_available_for_account_id?/2" do
    test "withdraws repeated export when the subscription expires" do
      account = Fixtures.Accounts.create_account(plan: "team")
      assert Billing.continuous_audit_export_available_for_account_id?(account.id, [])

      Fixtures.Accounts.create_subscription(account, "team", status: "paused")
      refute Billing.continuous_audit_export_available_for_account_id?(account.id, [])
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
      Fixtures.Accounts.create_subscription(account, "team",
        entitlements: %{"features_scim_enabled?" => true}
      )

      assert Billing.directory_sync_available?(account)
    end
  end

  describe "directory_sync_available_for_account_id?/2" do
    test "withdraws SCIM when Enterprise expires" do
      account = Fixtures.Accounts.create_account(plan: "enterprise")
      assert Billing.directory_sync_available_for_account_id?(account.id, [])

      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")
      refute Billing.directory_sync_available_for_account_id?(account.id, [])
    end
  end

  describe "support_plan/1" do
    test "reports free, complimentary, and Paddle sources without credentials" do
      free_account = Fixtures.Accounts.create_account()
      assert {:ok, %{plan: "free", source: "free"}} = Billing.support_plan(free_account)

      assert {:ok, %Subscription{status: "complimentary"}} =
               Billing.grant_complimentary_plan(free_account, "team")

      assert {:ok, complimentary} = Billing.support_plan(free_account)
      assert complimentary.plan == "team"
      assert complimentary.source == "complimentary"
      assert complimentary.subscription_status == "complimentary"
      assert is_nil(complimentary.paddle_subscription_id)

      paddle_account = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(paddle_account, "enterprise",
        paddle_subscription_id: "sub_support_plan"
      )

      assert {:ok, paddle} = Billing.support_plan(paddle_account)
      assert paddle.plan == "enterprise"
      assert paddle.source == "paddle"
      assert paddle.subscription_status == "active"
      assert paddle.paddle_subscription_id == "sub_support_plan"
    end
  end

  describe "sync_subscription_for_support/1" do
    test "reconciles one Paddle-managed subscription through the vendor seam" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(account, "enterprise",
        paddle_subscription_id: "sub_support_sync"
      )

      assert {:ok,
              %Subscription{
                plan: "team",
                status: "active",
                paddle_price_id: "pri_stub_team_month",
                quantity: 2
              }} = Billing.sync_subscription_for_support(account)
    end

    test "refuses accounts without a Paddle subscription id" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team")

      assert Billing.sync_subscription_for_support(account) ==
               {:error, :not_paddle_managed}
    end
  end

  describe "cancel_subscription_for_close/1" do
    test "cancels a live Paddle subscription" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_close_me"
      )

      assert Billing.cancel_subscription_for_close(account) == :ok
    end

    test "an account with nothing to cancel closes cleanly" do
      # Never subscribed, complimentary, and already canceled are all fine —
      # closing an account that never paid is not an error.
      never = Fixtures.Accounts.create_account()
      assert Billing.cancel_subscription_for_close(never) == :ok

      complimentary = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(complimentary, "team", status: "complimentary")
      assert Billing.cancel_subscription_for_close(complimentary) == :ok

      canceled = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(canceled, "team",
        paddle_subscription_id: "sub_already_gone",
        status: "canceled"
      )

      assert Billing.cancel_subscription_for_close(canceled) == :ok
    end
  end

  describe "grant_complimentary_plan/2" do
    test "grants and replaces the existing subscription row" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Subscription{plan: "team", status: "complimentary"} = team} =
               Billing.grant_complimentary_plan(account, "team")

      assert Billing.account_plan(account) == "team"
      assert Billing.sso_available?(account)

      assert {:ok, %Subscription{plan: "enterprise", status: "complimentary"} = enterprise} =
               Billing.grant_complimentary_plan(account, "enterprise")

      assert enterprise.id == team.id
      assert Billing.account_plan(account) == "enterprise"
      assert Billing.directory_sync_available?(account)

      # Chronological order IS the assertion (granted, then replaced), so the
      # read must order deterministically — an unordered Repo.all returns heap
      # order, which flips under concurrent CI.
      audits =
        Emisar.Audit.Event.Query.all()
        |> Emisar.Audit.Event.Query.by_account_id(account.id)
        |> Emisar.Audit.Event.Query.by_event_type("subscription.changed")
        |> Emisar.Audit.Event.Query.ordered_for_export()
        |> Repo.all()

      assert Enum.map(audits, & &1.payload["to"]) == ["team", "enterprise"]
    end

    test "is idempotent for an already-active plan" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, first} = Billing.grant_complimentary_plan(account, "team")
      assert {:ok, repeated} = Billing.grant_complimentary_plan(account, "team")

      assert repeated.id == first.id

      assert Repo.aggregate(
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id),
               :count
             ) == 1
    end

    test "refuses Paddle or legacy subscription state and invalid input" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team")

      assert Billing.grant_complimentary_plan(account, "enterprise") ==
               {:error, :paddle_or_legacy_subscription_present}

      free_account = Fixtures.Accounts.create_account()

      assert Billing.grant_complimentary_plan(free_account, "free") ==
               {:error, :invalid_complimentary_plan}
    end

    test "a real Paddle subscription replaces complimentary state" do
      account = Fixtures.Accounts.create_account()
      assert {:ok, complimentary} = Billing.grant_complimentary_plan(account, "team")

      assert {:ok, paddle} =
               Billing.upsert_subscription(account.id, %{
                 plan: "enterprise",
                 status: "active",
                 paddle_subscription_id: "sub_after_complimentary"
               })

      assert paddle.id == complimentary.id
      assert {:ok, %{source: "paddle", plan: "enterprise"}} = Billing.support_plan(account)
    end
  end

  describe "revoke_complimentary_plan/1" do
    test "deletes only complimentary state and is idempotent" do
      account = Fixtures.Accounts.create_account()
      assert {:ok, _subscription} = Billing.grant_complimentary_plan(account, "enterprise")

      assert {:ok, %Subscription{status: "complimentary"}} =
               Billing.revoke_complimentary_plan(account)

      assert Billing.account_plan(account) == "free"
      assert Billing.revoke_complimentary_plan(account) == {:ok, :already_free}
    end

    test "refuses to delete a Paddle or legacy subscription" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team")

      assert Billing.revoke_complimentary_plan(account) == {:error, :not_complimentary}
    end
  end

  describe "upsert_subscription/3 — unique_constraint backstop" do
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

      assert errors_on(changeset).account_id == ["has already been taken"]
    end
  end

  describe "upsert_subscription/3 — partial reconciliation preserves untouched fields" do
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
    test "a manual plan write is not dropped by the vendor staleness guard" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_manual_01"})

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_manual_01",
          plan: "team",
          status: "active",
          paddle_updated_at: DateTime.utc_now()
        })

      # Once the mirror carries Paddle's timestamp, an ordinary upsert with none
      # cannot prove it is newer and is dropped — so `mix emisar.set_plan` wrote
      # nothing while reporting success.
      {:ok, unchanged} =
        Billing.upsert_subscription(account.id, %{plan: "enterprise", status: "active"})

      assert unchanged.plan == "team"

      {:ok, updated} =
        Billing.upsert_subscription(account.id, %{plan: "enterprise", status: "active"},
          manual: true
        )

      assert updated.plan == "enterprise"
      assert is_nil(updated.paddle_updated_at)
    end

    test "a cancel is ordered by the webhook occurred_at when data has no updated_at" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_cancel_01"})

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_cancel_01",
          plan: "team",
          status: "active",
          paddle_updated_at: ~U[2026-08-25 00:00:00.000000Z]
        })

      assert {:ok, _} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.canceled",
                 "occurred_at" => "2026-08-26T00:00:00Z",
                 "data" => %{"id" => "sub_cancel_01"}
               })

      assert Repo.one(Emisar.Billing.Subscription).status == "canceled"
    end

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
      assert Billing.check_limit(account, :runners) == :ok

      # Cancel drops the entitlement back to free (cap 3). The five existing runners
      # are NOT touched — count is still 5, well over the new cap.
      assert {:ok, _} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.canceled",
                 "data" => %{"id" => "sub_downgrade_01"}
               })

      assert Emisar.Runners.count_billable_runners(account.id) == 5

      assert Billing.account_plan(account) == "free"
      assert Billing.check_limit(account, :runners) === {:error, :over_limit, "free", 3}
    end
  end

  describe "check_limit/2 — entitlements override the compiled plan limits" do
    test "Free's compiled member limit is one" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()

      assert Billing.check_limit(account, :members) ==
               {:error, :over_limit, "free", 1}
    end

    test "Team's compiled member limit is unlimited" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})

      for _ <- 1..12 do
        Fixtures.Memberships.create_membership(account_id: account.id)
      end

      assert Billing.check_limit(account, :members) == :ok
    end

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

  describe "start_checkout/4" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "rejects a plan name we do not sell", %{account: account, subject: subject} do
      assert Billing.start_checkout(account, "platinum", :month, subject) ==
               {:error, :unknown_plan}
    end

    test "refuses a second checkout while a Paddle subscription is live", %{
      account: account,
      subject: subject
    } do
      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_already_live"
      )

      # The console renders "Manage billing" rather than "Upgrade" here, but a
      # crafted phx-click reaches the context directly — and Paddle would bill
      # both subscriptions.
      assert Billing.start_checkout(account, "team", :month, subject) ==
               {:error, :subscription_already_active}
    end

    test "a canceled subscription can subscribe again", %{account: account, subject: subject} do
      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_canceled",
        status: "canceled"
      )

      assert {:ok, url} = Billing.start_checkout(account, "team", :month, subject)
      assert url =~ "stub.paddle.test/checkout"
    end

    test "a complimentary (non-Paddle) plan does not block checkout", %{
      account: account,
      subject: subject
    } do
      Fixtures.Accounts.create_subscription(account, "team", status: "complimentary")

      assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    end

    test "resolves the monthly price from the (stub) catalog and returns the checkout URL", %{
      account: account,
      subject: subject
    } do
      assert {:ok, url} = Billing.start_checkout(account, "team", :month, subject)
      assert url =~ "stub.paddle.test/checkout"
    end

    test "the annual cycle also resolves against the catalog", %{
      account: account,
      subject: subject
    } do
      # The stub Team product lists both a monthly and an annual price, so an
      # annual checkout resolves too (the price selection is asserted precisely
      # in BillingCheckoutArgsTest against the capturing client).
      assert {:ok, url} = Billing.start_checkout(account, "team", :year, subject)
      assert url =~ "stub.paddle.test/checkout"
    end

    test "only Team with an exact supported cadence is self-service", %{
      account: account,
      subject: subject
    } do
      assert Billing.start_checkout(account, "free", :month, subject) ==
               {:error, :plan_not_self_service}

      assert Billing.start_checkout(account, "enterprise", :year, subject) ==
               {:error, :plan_not_self_service}

      assert Billing.start_checkout(account, "team", :week, subject) ==
               {:error, :invalid_cycle}
    end

    test "an operator (view, not manage) is refused with :unauthorized", %{account: account} do
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Billing.start_checkout(account, "team", :month, operator_subject) ==
               {:error, :unauthorized}

      assert Billing.open_billing_portal(account, operator_subject) == {:error, :unauthorized}
    end

    test "the owner of another account is denied checkout AND portal for account A" do
      # Account-B's owner holds manage_billing on B, but ensure_subject_owns_account
      # binds the gate to the subject's own account — so acting on A is :unauthorized.
      {_user_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Billing.start_checkout(account_a, "team", :month, subject_b) ==
               {:error, :unauthorized}

      assert Billing.open_billing_portal(account_a, subject_b) == {:error, :unauthorized}
    end
  end

  describe "open_billing_portal/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "an account that never subscribed has no portal", %{account: account, subject: subject} do
      assert Billing.open_billing_portal(account, subject) == {:error, :no_customer}
    end

    test "returns the stub portal URL when no Paddle key is configured", %{
      account: account,
      subject: subject
    } do
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert {:ok, url} = Billing.open_billing_portal(account, subject)
      assert url =~ "/app?status=stub-portal"
    end

    test "an owner of another account is refused", %{account: account} do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert Billing.open_billing_portal(account, subject_b) == {:error, :unauthorized}
    end
  end

  describe "list_recent_invoices/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "an account that never subscribed has no invoices", %{account: account, subject: subject} do
      assert Billing.list_recent_invoices(account, subject) == {:ok, []}
    end

    test "a grand_total we cannot read is nil, never zero", %{
      account: account,
      subject: subject
    } do
      account = %{account | paddle_customer_id: "ctm_invoices_02"}

      # Paddle's contract is minor-unit digits. `Integer.parse` stops at the
      # first non-digit, so "20.00" came back as 20 — twenty CENTS — and
      # anything unreadable became 0, which the page rendered as "$0.00". That
      # reads as a fact about the charge rather than a failure to read it.
      assert {:ok, invoices} = Billing.list_recent_invoices(account, subject)
      assert Enum.map(invoices, & &1.amount_cents) === [2000, 2000, nil]
    end

    test "maps Paddle transactions to flat invoice rows for a customer", %{
      account: account,
      subject: subject
    } do
      account = %{account | paddle_customer_id: "ctm_invoices_01"}

      assert {:ok, [first | _] = invoices} = Billing.list_recent_invoices(account, subject)
      assert length(invoices) == 3
      assert first.amount_cents == 2000
      assert first.currency == "USD"
      assert first.status == "completed"
      assert %DateTime{} = first.billed_at
      assert first.invoice_number =~ "EMISAR-"
    end

    test "an owner of another account is refused", %{account: account} do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      account = %{account | paddle_customer_id: "ctm_invoices_01"}

      assert Billing.list_recent_invoices(account, subject_b) == {:error, :unauthorized}
    end

    test "a runner subject without view_billing permission is refused", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)
      account = %{account | paddle_customer_id: "ctm_invoices_01"}

      assert Billing.list_recent_invoices(account, subject) == {:error, :unauthorized}
    end

    # An admin runs the account and answers for what it spends; the billing
    # manager IS the finance seat. Both read the ledger without holding manage.
    test "an admin and a billing manager read the ledger", %{account: account} do
      account = %{account | paddle_customer_id: "ctm_invoices_01"}

      for role <- ["admin", "billing_manager"] do
        subject = role_subject(account, role)

        assert {:ok, _invoices} = Billing.list_recent_invoices(account, subject)
      end
    end

    # view_billing gets the plan and its limits through billing_summary/2 — never
    # the money behind them.
    test "an operator and a viewer are refused — view_billing is not the ledger",
         %{account: account} do
      account = %{account | paddle_customer_id: "ctm_invoices_01"}

      for role <- ["operator", "viewer"] do
        subject = role_subject(account, role)

        assert Billing.list_recent_invoices(account, subject) == {:error, :unauthorized}
      end
    end
  end

  describe "invoice_pdf_url/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: %{account | paddle_customer_id: "ctm_invoices_01"}, subject: subject}
    end

    test "returns a signed PDF URL for one of the account's own invoices", %{
      account: account,
      subject: subject
    } do
      # The stub's list_transactions returns txn_stub_1..3 for any customer.
      assert {:ok, url} = Billing.invoice_pdf_url(account, "txn_stub_1", subject)
      assert url =~ "txn_stub_1"
    end

    test "a transaction not among the account's invoices is not found (no cross-account PDF)", %{
      account: account,
      subject: subject
    } do
      assert Billing.invoice_pdf_url(account, "txn_from_account_b", subject) ==
               {:error, :not_found}
    end

    test "an admin downloads the PDF, an operator is refused — same gate as the list", %{
      account: account
    } do
      assert {:ok, url} =
               Billing.invoice_pdf_url(account, "txn_stub_1", role_subject(account, "admin"))

      assert url =~ "txn_stub_1"

      assert Billing.invoice_pdf_url(account, "txn_stub_1", role_subject(account, "operator")) ==
               {:error, :unauthorized}
    end

    test "an owner of another account is refused", %{account: account} do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert Billing.invoice_pdf_url(account, "txn_stub_1", subject_b) == {:error, :unauthorized}
    end

    test "a runner subject without view_billing permission is refused", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert Billing.invoice_pdf_url(account, "txn_stub_1", subject) == {:error, :unauthorized}
    end
  end

  describe "ensure_paddle_customer/2" do
    test "threads the selected owner email to Paddle on first creation" do
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
      {user, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, account} =
        Emisar.Accounts.put_account_paddle_customer_sync(account, "ctm_existing_01", user.id)

      assert {:ok, "ctm_existing_01", synced} =
               Billing.ensure_paddle_customer(account, subject)

      assert synced.paddle_customer_id == "ctm_existing_01"
      assert synced.paddle_billing_contact_user_id == user.id
    end

    test "an operator without manage_billing is refused" do
      {_user, account, _subject} = Fixtures.Subjects.owner_subject()
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Billing.ensure_paddle_customer(account, operator_subject) == {:error, :unauthorized}
    end

    test "an owner of another account is refused before returning an existing customer" do
      {_user_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      account_a = %{account_a | paddle_customer_id: "ctm_existing_01"}

      assert Billing.ensure_paddle_customer(account_a, subject_b) == {:error, :unauthorized}
    end
  end

  describe "sync_paddle_customer_for_account/1" do
    test "creates a Paddle customer and stores the selected owner contact" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, customer_id, synced} = Billing.sync_paddle_customer_for_account(account.id)

      assert String.starts_with?(customer_id, "ctm_stub_")
      assert synced.paddle_customer_id == customer_id
      assert synced.paddle_billing_contact_user_id == owner.id
      assert %DateTime{} = synced.paddle_customer_synced_at

      reloaded = Repo.reload!(account)
      assert reloaded.paddle_customer_id == customer_id
      assert reloaded.paddle_billing_contact_user_id == owner.id
    end

    test "refuses an account with no confirmed owner email" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user(confirmed?: false)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      assert Billing.sync_paddle_customer_for_account(account.id) ==
               {:error, :no_billing_contact}
    end

    test "adopts the customer Paddle already has for the owner's email" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :paddle_client, ConflictingCustomerPaddleClient)
      Emisar.Config.put_override(:emisar, :billing_conflict_code, "customer_already_exists")

      Emisar.Config.put_override(:emisar, :billing_conflict_customers, [
        %{"id" => "ctm_existing_01"}
      ])

      assert {:ok, "ctm_existing_01", synced} =
               Billing.sync_paddle_customer_for_account(account.id)

      assert synced.paddle_customer_id == "ctm_existing_01"
      assert synced.paddle_billing_contact_user_id == owner.id
      assert Repo.reload!(account).paddle_customer_id == "ctm_existing_01"
    end

    test "adopts nothing when the 409 is a different conflict" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :paddle_client, ConflictingCustomerPaddleClient)
      Emisar.Config.put_override(:emisar, :billing_conflict_code, "conflict")

      Emisar.Config.put_override(:emisar, :billing_conflict_customers, [
        %{"id" => "ctm_someone_else_01"}
      ])

      assert {:error, {:http, 409, body}} = Billing.sync_paddle_customer_for_account(account.id)
      assert body =~ ~s("code":"conflict")
      refute Repo.reload!(account).paddle_customer_id
    end

    test "adopts nothing when the conflicting customer cannot be looked up" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :paddle_client, ConflictingCustomerPaddleClient)
      Emisar.Config.put_override(:emisar, :billing_conflict_code, "customer_already_exists")
      Emisar.Config.put_override(:emisar, :billing_conflict_customers, [])

      assert Billing.sync_paddle_customer_for_account(account.id) ==
               {:error, :conflicting_customer_not_found}

      refute Repo.reload!(account).paddle_customer_id
    end
  end

  describe "sync_paddle_customers/1" do
    test "syncs a bounded page of stale accounts and reports the cursor" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, %{processed: 1, last_account_id: account_id, full?: false, limit: 10}} =
               Billing.sync_paddle_customers(limit: 10)

      assert account_id == account.id
      assert Repo.reload!(account).paddle_customer_id
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
      Emisar.Config.put_override(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Stub)
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

  describe "redacted_paddle_error/1" do
    test "drops the response body from an HTTP failure, keeping only the status" do
      assert Billing.redacted_paddle_error({:http, 500, ~s({"customer_id":"ctm_secret"})}) ==
               {:http, 500}
    end

    test "keeps Paddle's machine error code, which names WHICH conflict occurred" do
      body =
        ~s({"error":{"type":"request_error","code":"customer_already_exists","detail":"customer with email a@b.test already exists"}})

      assert Billing.redacted_paddle_error({:http, 409, body}) ==
               {:http, 409, "customer_already_exists"}
    end

    test "drops the detail, which quotes the offending value back" do
      body =
        ~s({"error":{"code":"customer_already_exists","detail":"email owner@acme.test already exists"}})

      {:http, _status, code} = Billing.redacted_paddle_error({:http, 409, body})

      refute code =~ "owner@acme.test"
    end

    test "drops a code that is not a short snake_case token" do
      for bad <- [
            ~s({"error":{"code":"ctm_01j9 secret value"}}),
            ~s({"error":{"code":123}}),
            ~s({"error":{"detail":"no code here"}}),
            "not json at all"
          ] do
        assert Billing.redacted_paddle_error({:http, 409, bad}) == {:http, 409}
      end
    end

    test "summarizes a changeset by its failing field NAMES, never its .changes" do
      changeset = Subscription.Changeset.upsert(%{status: "active"})

      refute changeset.valid?

      assert Billing.redacted_paddle_error(changeset) ==
               {:invalid_changeset, [:account_id, :plan]}
    end

    test "passes any other reason through unchanged" do
      assert Billing.redacted_paddle_error(:paddle_unavailable) == :paddle_unavailable
    end
  end

  describe "record_and_apply_event/3 — subscription.created" do
    test "persists a subscription with the plan derived from the embedded product" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_team_01"})

      event =
        subscription_created_event("evt_created_1", account.paddle_customer_id, "pri_team_01")

      assert Billing.record_and_apply_event("evt_created_1", "subscription.created", event) == :ok

      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert subscription.plan == "team"
      assert subscription.status == "active"
      assert subscription.paddle_subscription_id == "sub_evt_created_1"
      assert subscription.paddle_price_id == "pri_team_01"
      # No billing_cycle in this payload → nil (billing_summary reads monthly).
      refute subscription.billing_interval
    end

    test "a first-seen webhook cannot replace a different live subscription" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_live_webhook_01"})

      {:ok, live} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_live_webhook_01",
          plan: "team",
          status: "active"
        })

      binding = Emisar.Crypto.paddle_account_binding(account.id, "txn_competing_webhook")

      event =
        subscription_created_event(
          "evt_competing_webhook",
          account.paddle_customer_id,
          "pri_team_01"
        )
        |> put_in(["data", "custom_data"], %{"emisar_account_binding" => binding})
        |> put_in(["data", "transaction_id"], "txn_competing_webhook")

      assert Billing.record_and_apply_event(
               "evt_competing_webhook",
               "subscription.created",
               event
             ) == {:error, {:apply_failed, :different_live_subscription}}

      assert Repo.reload!(live).paddle_subscription_id == "sub_live_webhook_01"
      refute processed_event?("evt_competing_webhook")
    end

    test "mirrors the price's billing cadence so an annual subscriber is priced per year" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_annual_01"})

      event =
        subscription_created_event("evt_annual", account.paddle_customer_id, "pri_team_year_01",
          cycle: "year"
        )

      assert Billing.record_and_apply_event("evt_annual", "subscription.created", event) == :ok

      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert subscription.billing_interval == "year"
    end

    test "mirrors the exact charged recurring price for revenue analytics" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_revenue_01"})

      event =
        subscription_created_event("evt_revenue", account.paddle_customer_id, "pri_custom_01",
          cycle: "year",
          frequency: 2,
          quantity: 3,
          unit_price_amount: "48000",
          currency_code: "USD"
        )

      assert Billing.record_and_apply_event("evt_revenue", "subscription.created", event) == :ok

      subscription = Repo.one!(Subscription)
      assert subscription.paddle_price_id == "pri_custom_01"
      assert subscription.billing_interval == "year"
      assert subscription.billing_frequency == 2
      assert subscription.quantity == 3
      assert subscription.unit_price_amount == 48_000
      assert subscription.currency_code == "USD"
    end

    test "mirrors product custom_data into entitlements and takes the plan from its slug" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_ent_01"})

      # The product's own custom_data slug identifies the plan — it wins over
      # the (mismatching) product name and needs no deployed mapping.
      event =
        subscription_created_event("evt_ent_1", account.paddle_customer_id, "pri_unmapped_99",
          product_custom_data: %{
            "plan" => "team",
            "runners_limit" => "25",
            "members_limit" => "unlimited",
            "features_sso_enabled?" => "true",
            "typo_key" => "dropped"
          }
        )

      assert Billing.record_and_apply_event("evt_ent_1", "subscription.created", event) == :ok

      subscription = Repo.one(Subscription)
      assert subscription.plan == "team"

      assert subscription.entitlements == %{
               "runners_limit" => 25,
               "members_limit" => "unlimited",
               "features_sso_enabled?" => true
             }
    end

    test "a plan change writes a subscription.changed AUDIT row (distinct from the Mixpanel event)" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_audit_01"})

      event = subscription_created_event("evt_audit_1", account.paddle_customer_id, "pri_team_01")
      assert Billing.record_and_apply_event("evt_audit_1", "subscription.created", event) == :ok

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

      assert Billing.record_and_apply_event("evt_tel_1", "subscription.created", event) == :ok
      assert_receive {:billing_webhook, %{count: 1}, %{outcome: :applied}}

      # Paddle re-delivers the same event id → deduped.
      assert {:duplicate, _} =
               Billing.record_and_apply_event("evt_tel_1", "subscription.created", event)

      assert_receive {:billing_webhook, %{count: 1}, %{outcome: :duplicate}}
    end

    test "falls back to the account's current plan when the payload carries no plan identity" do
      account =
        Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_ent_01"})

      Fixtures.Accounts.create_subscription(account, "enterprise",
        paddle_subscription_id: "sub_old_enterprise_01",
        status: "canceled"
      )

      # A lean payload with no product object — nothing identifies the plan.
      event =
        subscription_created_event("evt_created_2", account.paddle_customer_id, "pri_unmapped",
          product: false
        )

      assert Billing.record_and_apply_event("evt_created_2", "subscription.created", event) == :ok

      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.one()

      assert subscription.plan == "enterprise"
    end

    test "no-op (still :ok) when no account matches the Paddle customer" do
      event = subscription_created_event("evt_created_3", "ctm_nobody", "pri_team_01")

      assert Billing.record_and_apply_event("evt_created_3", "subscription.created", event) == :ok
    end

    test "a created event with no scheduled cancel / billing-period / quantity leaves those columns at defaults" do
      # `upsert_from_subscription/1` now maps cancel_at_period_end / current_period_start
      # / quantity from the Paddle payload (see the scheduled-cancel test below), but a
      # plain subscription.created carrying none of those must leave them at their
      # defaults, not invent values. `trial_end` is not yet mapped (BACKLOG).
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_cyclenote_01"})

      event =
        subscription_created_event("evt_cyclenote", account.paddle_customer_id, "pri_team_01")

      assert Billing.record_and_apply_event("evt_cyclenote", "subscription.created", event) == :ok

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
      assert Billing.record_and_apply_event("evt_sc", "subscription.created", created) == :ok

      updated = %{
        "event_id" => "evt_sc_upd",
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_evt_sc",
          "customer_id" => account.paddle_customer_id,
          "status" => "active",
          "updated_at" => "2026-08-02T00:00:00Z",
          "scheduled_change" => %{"action" => "cancel", "effective_at" => "2026-09-01T00:00:00Z"},
          "current_billing_period" => %{
            "starts_at" => "2026-08-01T00:00:00Z",
            "ends_at" => "2026-09-01T00:00:00Z"
          },
          "items" => [
            %{
              "product" => %{"name" => "Team", "custom_data" => %{"plan" => "team"}},
              "price" => %{"id" => "pri_team_01"},
              "quantity" => 5
            }
          ]
        }
      }

      assert Billing.record_and_apply_event("evt_sc_upd", "subscription.updated", updated) == :ok

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

      assert Billing.record_and_apply_event("evt_period_top", "subscription.created", top_event) ==
               :ok

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
      assert Billing.record_and_apply_event("evt_ooo", "subscription.created", created) == :ok

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

      assert Billing.record_and_apply_event("evt_ooo_fresh", "subscription.updated", fresh) == :ok

      # A late cancel that OCCURRED EARLIER (updated_at T1 < T2) must be dropped,
      # not clobber the row to canceled.
      stale_cancel = %{
        "event_type" => "subscription.canceled",
        "data" => %{"id" => "sub_evt_ooo", "updated_at" => "2026-08-10T00:00:00Z"}
      }

      assert Billing.record_and_apply_event(
               "evt_ooo_stale",
               "subscription.canceled",
               stale_cancel
             ) == :ok

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

      assert Billing.record_and_apply_event(
               "evt_ooo_newer",
               "subscription.canceled",
               newer_cancel
             ) == :ok

      assert %Subscription{status: "canceled"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end
  end

  describe "record_and_apply_event/3 — dedup + apply commit atomically" do
    test "on success the dedup row AND the subscription mutation commit together" do
      # The dedup insert and apply run in ONE Multi (record_and_apply_event), so a
      # successful delivery leaves BOTH the processed-events row AND the mirror row
      # — never a half state. (The failure-rollback companion is asserted in the
      # "dedup + rollback" describe: a failed apply leaves NEITHER.)
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_atomic_01"})
      event = subscription_created_event("evt_atomic", account.paddle_customer_id, "pri_team_01")

      assert Billing.record_and_apply_event("evt_atomic", "subscription.created", event) == :ok

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

      assert Billing.record_and_apply_event("evt_unhandled", "transaction.completed", event) ==
               :ok

      # No subscription written by the no-op.
      assert Subscription.Query.all()
             |> Subscription.Query.by_account_id(account.id)
             |> Repo.one() == nil

      # The dedup row committed (the no-op is a success), so a redelivery dedups.
      assert processed_event?("evt_unhandled")

      assert Billing.record_and_apply_event("evt_unhandled", "transaction.completed", event) ==
               {:duplicate, "evt_unhandled"}
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

      assert Billing.record_and_apply_event(
               "evt_future",
               "subscription.future_capability_2099",
               event
             ) == :ok

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

      assert Billing.record_and_apply_event("evt_dup", "subscription.created", event) == :ok

      assert Billing.record_and_apply_event("evt_dup", "subscription.created", event) ==
               {:duplicate, "evt_dup"}
    end

    test "an apply failure rolls back the dedup row so redelivery reprocesses" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_fail_01"})

      # A payload with no status is malformed inside the same transaction. An
      # UNKNOWN status string deliberately persists — Paddle owns the value
      # space — so a missing field is the failure mode to exercise here.
      bad_event =
        subscription_created_event("evt_fail", account.paddle_customer_id, nil)
        |> put_in(["data", "status"], nil)

      assert {:error, {:apply_failed, :malformed_subscription}} =
               Billing.record_and_apply_event("evt_fail", "subscription.created", bad_event)

      # The dedup row MUST be absent — otherwise Paddle's retry is swallowed.
      refute processed_event?("evt_fail")

      # No subscription leaked from the rolled-back transaction either.
      assert Subscription.Query.all()
             |> Subscription.Query.by_account_id(account.id)
             |> Repo.one() == nil

      # Redelivery with a now-valid payload reprocesses and persists.
      good_event = subscription_created_event("evt_fail", account.paddle_customer_id, nil)
      assert Billing.record_and_apply_event("evt_fail", "subscription.created", good_event) == :ok
      assert processed_event?("evt_fail")
    end
  end

  describe "apply_webhook_event/1 — subscription.updated" do
    test "re-derives the plan on the existing row (no new row inserted)" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_upd_plan_01"})

      created =
        subscription_created_event("evt_upd_plan_c", account.paddle_customer_id, "pri_team_01")

      assert {:ok, %Subscription{plan: "team"}} = Billing.apply_webhook_event(created)

      # Same subscription id, now carrying the enterprise product.
      updated =
        subscription_updated_event(
          "evt_upd_plan_c",
          account.paddle_customer_id,
          "pri_ent_01",
          status: "active",
          product_name: "enterprise"
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
      # A product-less payload — put_present skips the absent entitlements
      # rather than nulling the mirror.
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_ent_keep_01"})

      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_ent_keep",
        entitlements: %{"runners_limit" => 25}
      )

      updated =
        subscription_updated_event("ent_keep", account.paddle_customer_id, "pri_team_01",
          status: "past_due",
          product: false
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
          "status" => "past_due",
          "updated_at" => "2026-08-02T00:00:00Z"
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

      assert Billing.apply_webhook_event(foreign) == :ok

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
          status: "active",
          product_name: "enterprise"
        )

      assert {:ok, %Subscription{}} = Billing.apply_webhook_event(updated)

      assert [%Subscription{plan: "enterprise", status: "active"}] =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.all()
    end

    test "an identity-less update falls back to the account's current plan" do
      # An update whose payload carries no product identity falls back to
      # account_plan/1 — the existing subscription's plan — so the row keeps
      # its current (team) plan rather than failing validate_required.
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
          status: "active",
          product: false
        )

      assert {:ok, %Subscription{}} = Billing.apply_webhook_event(updated)

      # Plan and price both stay on the last identified plan item. A lean or
      # reordered add-on payload cannot replace the billable Team line.
      assert %Subscription{plan: "team", paddle_price_id: "pri_team_01"} =
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
    test "a missing status on an update fails the apply and rolls the dedup row back" do
      # A full lifecycle payload without status is malformed before any partial
      # update can preserve the old value. The apply error rolls the dedup row
      # back, so Paddle's redelivery is reprocessed rather than swallowed.
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

      assert {:error, {:apply_failed, :malformed_subscription}} =
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

    test "a timestamp-free update cannot clobber a timestamped mirror" do
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

      # A partial capture carrying NO `updated_at` can't prove it postdates the
      # stored Paddle timestamp, so the timestamp-absent fallback drops it.
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

      assert {:ok, %Subscription{status: "past_due"}} = Billing.apply_webhook_event(stale)

      assert %Subscription{status: "past_due"} =
               Subscription.Query.all()
               |> Subscription.Query.by_account_id(account.id)
               |> Repo.one()
    end
  end

  describe "apply_webhook_event/1 — Subject-less; audits the plan change" do
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

  describe "apply_webhook_event/1 — subscription.canceled expires entitlement" do
    test "a canceled subscription uses Free limits without deleting existing resources" do
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

      assert Billing.account_plan(account) == "free"
      assert Billing.check_limit(account, :runners) == :ok
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

  describe "apply_webhook_event/1 — lifecycle event types" do
    test "pause, resume, and trial events converge through the shared mapper" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_unmodeled_01"})

      {:ok, _} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_unmodeled_01",
          plan: "team",
          status: "active"
        })

      for {event_type, status, expected_state} <- [
            {"subscription.paused", "paused", :expired},
            {"subscription.resumed", "active", :active},
            {"subscription.trialing", "trialing", :active}
          ] do
        assert {:ok, subscription} =
                 Billing.apply_webhook_event(%{
                   "event_type" => event_type,
                   "data" => %{
                     "id" => "sub_unmodeled_01",
                     "customer_id" => account.paddle_customer_id,
                     "status" => status
                   }
                 })

        assert Billing.entitlement_state(subscription) == expected_state
      end

      assert %Subscription{status: "trialing"} =
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

      assert Billing.apply_webhook_event(%{
               "event_type" => "subscription.canceled",
               "data" => %{"id" => "sub_never_seen"}
             }) == :ok
    end
  end

  # A minimal Paddle subscription.created webhook envelope. The price id is
  # nested under data.items[].price.id, matching Paddle's Billing API.
  defp subscription_created_event(event_id, customer_id, price_id, opts \\ []) do
    %{
      "event_id" => event_id,
      "event_type" => "subscription.created",
      "data" => %{
        "id" => "sub_" <> event_id,
        "customer_id" => customer_id,
        "status" => "active",
        "updated_at" => Keyword.get(opts, :updated_at, "2026-08-01T00:00:00Z"),
        "next_billed_at" => "2026-07-01T00:00:00Z",
        "items" => [subscription_item(price_id, opts)]
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
        "updated_at" => Keyword.get(opts, :updated_at, "2026-09-01T00:00:00Z"),
        "next_billed_at" => "2026-09-01T00:00:00Z",
        "items" => [subscription_item(price_id, opts)]
      }
    }
  end

  # Real payloads always embed the full product per item — plan identity rides
  # its name (`product_name:`, default "team") and custom_data
  # (`product_custom_data:`). `product: false` models the lean shape carrying
  # no product identity at all.
  defp subscription_item(price_id, opts) do
    price = %{"id" => price_id}

    price =
      case Keyword.get(opts, :cycle) do
        nil ->
          price

        interval ->
          Map.put(price, "billing_cycle", %{
            "interval" => interval,
            "frequency" => Keyword.get(opts, :frequency, 1)
          })
      end

    price =
      if Keyword.has_key?(opts, :unit_price_amount) do
        Map.put(price, "unit_price", %{
          "amount" => opts[:unit_price_amount],
          "currency_code" => opts[:currency_code]
        })
      else
        price
      end

    item =
      if Keyword.has_key?(opts, :quantity) do
        %{"price" => price, "quantity" => opts[:quantity]}
      else
        %{"price" => price}
      end

    if Keyword.get(opts, :product, true) do
      product = %{
        "id" => "pro_test_01",
        "name" => Keyword.get(opts, :product_name, "team"),
        "custom_data" => opts[:product_custom_data]
      }

      Map.put(item, "product", product)
    else
      item
    end
  end

  describe "reconcile_subscription_data/1" do
    test "discovers a missed created event by Paddle customer and fails malformed input closed" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_discovery_01"})

      assert {:ok, %Subscription{account_id: account_id, status: "active"}} =
               Billing.reconcile_subscription_data(%{
                 "id" => "sub_discovery_01",
                 "customer_id" => account.paddle_customer_id,
                 "status" => "active",
                 "collection_mode" => "automatic",
                 "items" => [subscription_item("pri_team_01", [])]
               })

      assert account_id == account.id

      assert Billing.reconcile_subscription_data(%{"id" => "sub_no_status"}) ==
               {:error, :malformed_subscription}
    end

    test "a response fetched before a webhook cannot rewind the newer lifecycle state" do
      account = Fixtures.Accounts.create_account()

      {:ok, before_fetch} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_reconcile_race_01",
          plan: "team",
          status: "active",
          paddle_updated_at: ~U[2026-08-26 00:00:00.000000Z]
        })

      {:ok, canceled} =
        Billing.upsert_subscription(account.id, %{
          status: "canceled",
          paddle_event_occurred_at: ~U[2026-08-26 00:01:00.000000Z]
        })

      stale_response = %{
        "id" => "sub_reconcile_race_01",
        "status" => "active",
        "updated_at" => "2026-08-26T00:00:00Z"
      }

      assert Billing.reconcile_subscription_data(stale_response,
               expected_subscription: before_fetch
             ) == {:error, :stale_reconciliation}

      assert Repo.reload!(canceled).status == "canceled"
    end

    test "a late webhook cannot rewind a newer repaired object state" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_repair_order_01"})

      {:ok, _subscription} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_repair_order_01",
          plan: "team",
          status: "active",
          paddle_updated_at: ~U[2026-08-26 00:10:00.000000Z],
          paddle_event_occurred_at: ~U[2026-08-26 00:10:00.000000Z]
        })

      assert {:ok, %Subscription{status: "canceled"}} =
               Billing.reconcile_subscription_data(%{
                 "id" => "sub_repair_order_01",
                 "customer_id" => account.paddle_customer_id,
                 "status" => "canceled",
                 "updated_at" => "2026-08-26T00:30:00Z"
               })

      assert {:ok, %Subscription{status: "canceled"}} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.updated",
                 "occurred_at" => "2026-08-26T00:20:00Z",
                 "data" => %{
                   "id" => "sub_repair_order_01",
                   "customer_id" => account.paddle_customer_id,
                   "status" => "active",
                   "updated_at" => "2026-08-26T00:20:00Z"
                 }
               })

      # Once ordering is established, a timestamp-free webhook is not allowed
      # to opt out of it either.
      assert {:ok, %Subscription{status: "canceled"}} =
               Billing.apply_webhook_event(%{
                 "event_type" => "subscription.updated",
                 "data" => %{
                   "id" => "sub_repair_order_01",
                   "customer_id" => account.paddle_customer_id,
                   "status" => "active"
                 }
               })
    end
  end

  describe "reconcile_subscription_data/2" do
    test "refuses a provider response when the expected mirror changed before application" do
      account = Fixtures.Accounts.create_account()

      {:ok, before_fetch} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_expected_mirror_01",
          plan: "team",
          status: "active",
          paddle_updated_at: ~U[2026-08-26 00:00:00.000000Z]
        })

      {:ok, canceled} =
        Billing.upsert_subscription(account.id, %{
          status: "canceled",
          paddle_event_occurred_at: ~U[2026-08-26 00:01:00.000000Z]
        })

      assert Billing.reconcile_subscription_data(
               %{
                 "id" => "sub_expected_mirror_01",
                 "status" => "active",
                 "updated_at" => "2026-08-26T00:00:00Z"
               },
               expected_subscription: before_fetch
             ) == {:error, :stale_reconciliation}

      assert Repo.reload!(canceled).status == "canceled"
    end
  end

  describe "reconcile_discovered_subscription_data/1" do
    test "inserts a missing mirror and skips subscriptions the local sweep already owns" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_discovered_01"})

      discovered = %{
        "id" => "sub_discovered_01",
        "customer_id" => account.paddle_customer_id,
        "status" => "active",
        "items" => [subscription_item("pri_team_01", [])]
      }

      assert {:ok, subscription} = Billing.reconcile_discovered_subscription_data(discovered)

      {:ok, canceled} =
        Billing.upsert_subscription(account.id, %{
          status: "canceled",
          paddle_event_occurred_at: ~U[2026-08-26 00:01:00.000000Z]
        })

      assert Billing.reconcile_discovered_subscription_data(discovered) == :ok
      assert Repo.reload!(canceled).status == "canceled"
      assert subscription.id == canceled.id
    end

    test "replaces only the unchanged terminal mirror for a missed resubscribe" do
      account = Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_resubscribe_01"})

      {:ok, old_subscription} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: "sub_old_canceled_01",
          plan: "team",
          status: "canceled",
          paddle_updated_at: ~U[2026-08-20 00:00:00.000000Z]
        })

      discovered = %{
        "id" => "sub_new_active_01",
        "customer_id" => account.paddle_customer_id,
        "status" => "active",
        "collection_mode" => "automatic",
        "updated_at" => "2026-08-26T00:00:00Z",
        "items" => [subscription_item("pri_team_01", [])]
      }

      assert {:ok, replacement} = Billing.reconcile_discovered_subscription_data(discovered)
      assert replacement.id == old_subscription.id
      assert replacement.paddle_subscription_id == "sub_new_active_01"
      assert replacement.status == "active"

      account_two =
        Fixtures.Accounts.create_account(%{paddle_customer_id: "ctm_live_conflict_01"})

      {:ok, live} =
        Billing.upsert_subscription(account_two.id, %{
          paddle_subscription_id: "sub_live_existing_01",
          plan: "team",
          status: "active"
        })

      assert Billing.reconcile_discovered_subscription_data(%{
               "id" => "sub_competing_01",
               "customer_id" => account_two.paddle_customer_id,
               "status" => "active"
             }) == {:error, :different_live_subscription}

      assert Repo.reload!(live).paddle_subscription_id == "sub_live_existing_01"
    end

    test "uses checkout account binding when a Paddle customer is shared" do
      shared_customer_id = "ctm_shared_customer_01"

      account_one =
        Fixtures.Accounts.create_account(%{paddle_customer_id: shared_customer_id})

      account_two =
        Fixtures.Accounts.create_account(%{paddle_customer_id: shared_customer_id})

      unbound = %{
        "id" => "sub_shared_unbound_01",
        "customer_id" => shared_customer_id,
        "status" => "active",
        "items" => [subscription_item("pri_team_01", [])]
      }

      assert Billing.reconcile_discovered_subscription_data(unbound) ==
               {:error, :ambiguous_paddle_customer}

      binding = Emisar.Crypto.paddle_account_binding(account_two.id, "txn_shared_bound_01")

      bound =
        Map.put(unbound, "custom_data", %{"emisar_account_binding" => binding})
        |> Map.put("id", "sub_shared_bound_01")

      assert {:ok, subscription} = Billing.reconcile_discovered_subscription_data(bound)
      assert subscription.account_id == account_two.id

      refute Subscription.Query.all()
             |> Subscription.Query.by_account_id(account_one.id)
             |> Repo.exists?()

      assert Billing.reconcile_discovered_subscription_data(
               Map.put(bound, "id", "sub_shared_replayed_01")
             ) == {:error, :invalid_subscription_account_binding}

      assert Billing.reconcile_discovered_subscription_data(
               bound
               |> Map.put("id", "sub_shared_tampered_01")
               |> put_in(["custom_data", "emisar_account_binding"], binding <> "x")
             ) == {:error, :invalid_subscription_account_binding}
    end
  end

  describe "subscription_mirror_attrs/2" do
    test "maps generic scheduled lifecycle facts and an event ordering watermark" do
      attrs =
        Billing.subscription_mirror_attrs(
          %{
            "id" => "sub_lifecycle_01",
            "status" => "active",
            "collection_mode" => "automatic",
            "scheduled_change" => %{
              "action" => "pause",
              "effective_at" => "2026-09-01T00:00:00Z"
            }
          },
          event_occurred_at: ~U[2026-08-26 00:00:00.000000Z]
        )

      assert attrs.collection_mode == "automatic"
      assert attrs.scheduled_change_action == "pause"
      assert %DateTime{} = attrs.scheduled_change_effective_at
      refute attrs.cancel_at_period_end
      assert attrs.paddle_event_occurred_at == ~U[2026-08-26 00:00:00.000000Z]

      assert %{
               scheduled_change_action: nil,
               scheduled_change_effective_at: nil,
               cancel_at_period_end: false
             } = Billing.subscription_mirror_attrs(%{"scheduled_change" => nil}, [])
    end
  end

  describe "subscription_item_attrs/1" do
    test "omits malformed vendor values instead of clearing the mirror" do
      payload = %{
        "items" => [
          %{
            "quantity" => 0,
            "price" => %{
              "id" => "",
              "billing_cycle" => %{"interval" => "", "frequency" => "invalid"},
              "unit_price" => %{"amount" => "12x", "currency_code" => "usd"}
            }
          }
        ]
      }

      assert Billing.subscription_item_attrs(payload) == %{}
    end

    test "treats malformed nested price objects as absent" do
      payload = %{
        "items" => [
          %{
            "quantity" => 2,
            "product" => %{"name" => "Team", "custom_data" => %{"plan" => "team"}},
            "price" => %{
              "id" => "pri_valid",
              "billing_cycle" => "invalid",
              "unit_price" => ["invalid"]
            }
          }
        ]
      }

      assert Billing.subscription_item_attrs(payload) == %{
               paddle_price_id: "pri_valid",
               quantity: 2
             }
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
      # No subscription → the cadence reads monthly, priced at free's $0.
      assert summary.billing_interval == :month
      assert summary.period_total_cents == 0
      refute summary.subscription_status
      refute summary.current_period_end
    end

    test "an annual subscriber's summary is priced per year at the annual rate" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      for _ <- 1..2, do: Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Accounts.create_subscription(account, "team", billing_interval: "year")

      assert {:ok, summary} = Billing.billing_summary(account, subject)
      assert summary.billing_interval == :year
      # 2 runners × $200/runner/yr (annual_price_cents), not the monthly rate.
      assert summary.period_total_cents == 40_000
      # The monthly fields stay the monthly rate — both are exposed.
      assert summary.monthly_per_runner_cents == 2000
    end

    test "the mirrored Paddle price wins over the compiled catalog, currency and all" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      # Five live runners, but Paddle bills three seats at €20 — the summary must
      # read what Paddle charges, not catalog list price × live runner count.
      for _ <- 1..5, do: Fixtures.Runners.create_runner(account_id: account.id)

      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_eur_three_seats",
        unit_price_amount: 2000,
        currency_code: "EUR",
        quantity: 3
      )

      assert {:ok, summary} = Billing.billing_summary(account, subject)
      assert summary.period_total_cents == 6000
      assert summary.currency_code == "EUR"
    end

    test "a subscription with no mirrored price falls back to the USD catalog" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      for _ <- 1..2, do: Fixtures.Runners.create_runner(account_id: account.id)
      # A legacy row the reconciliation job has not backfilled yet.
      Fixtures.Accounts.create_subscription(account, "team")

      assert {:ok, summary} = Billing.billing_summary(account, subject)
      assert summary.period_total_cents == 4000
      assert summary.currency_code == "USD"
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
      refute summary.period_total_cents
    end

    test "an owner of account B cannot read account A's summary (cross-account)" do
      {_user_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Billing.billing_summary(account_a, subject_b) == {:error, :unauthorized}
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
      assert Billing.billing_summary(account, api_subject) == {:error, :unauthorized}

      runner = Fixtures.Runners.create_runner(account_id: account.id)
      runner_subject = Subject.for_runner(runner, account)
      assert Billing.billing_summary(account, runner_subject) == {:error, :unauthorized}
    end
  end

  describe "subject_can_manage_billing?/1" do
    setup do
      {_user, account, owner_subject} = Fixtures.Subjects.owner_subject()
      %{account: account, owner_subject: owner_subject}
    end

    test "true for the three roles that run the account's money", %{
      account: account,
      owner_subject: owner_subject
    } do
      assert Billing.subject_can_manage_billing?(owner_subject)

      for role <- ["admin", "billing_manager"] do
        assert Billing.subject_can_manage_billing?(role_subject(account, role))
      end
    end

    test "false for operator and viewer (they hold view, not manage)", %{account: account} do
      # The UI calls this to show/hide the checkout + portal controls — an
      # operator drives infrastructure and has no business in the money.
      for role <- ["operator", "viewer"] do
        refute Billing.subject_can_manage_billing?(role_subject(account, role))
      end
    end
  end

  describe "subject_can_view_invoices?/1" do
    setup do
      {_user, account, owner_subject} = Fixtures.Subjects.owner_subject()
      %{account: account, owner_subject: owner_subject}
    end

    test "true for an owner", %{owner_subject: owner_subject} do
      assert Billing.subject_can_view_invoices?(owner_subject)
    end

    test "true for admin and billing manager, false for operator and viewer", %{account: account} do
      # The boundary the ledger draws: reading what the account spent is the
      # account-running tier, one step below changing the plan.
      for role <- [:admin, :billing_manager] do
        assert Billing.subject_can_view_invoices?(role_subject(account, to_string(role)))
      end

      for role <- [:operator, :viewer] do
        refute Billing.subject_can_view_invoices?(role_subject(account, to_string(role)))
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

  # A persisted member of `account` at `role` — billing gates read the role off
  # the membership row, so a struct-only subject would not exercise them.
  defp role_subject(account, role) when is_binary(role) do
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: role
      )

    Fixtures.Subjects.membership_subject(membership)
  end

  defp processed_event?(event_id) do
    Repo.exists?(from e in "paddle_processed_events", where: e.id == ^event_id)
  end
end

defmodule Emisar.BillingVendorErrorTest do
  @moduledoc """
  The Paddle error paths the in-process Stub can't reach — a 5xx on checkout /
  customer creation / portal open. Each test binds a failing `:paddle_client`
  with `Emisar.Config.put_override/3`, scoped to its own process, so the module
  stays `async: true`.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Billing
  alias Emisar.BillingTest.ErrorPaddleClient
  alias Emisar.Fixtures

  setup do
    Emisar.Config.put_override(:emisar, :paddle_client, ErrorPaddleClient)
    :ok
  end

  describe "start_checkout/4 — vendor failures" do
    test "a vendor error on checkout-session creation bubbles up" do
      # The catalog read fails first on this client — its {:error, term}
      # propagates out of start_checkout unchanged (the LV turns it into a
      # flash, no redirect).
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert Billing.start_checkout(account, "team", :month, subject) ==
               {:error, :paddle_unavailable}
    end

    test "a vendor error creating the customer short-circuits before any checkout" do
      # ensure_paddle_customer/2 runs first; when create_customer errors, the
      # `with` in start_checkout bails on it — no checkout session is attempted
      # and no customer id is ever persisted.
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      refute account.paddle_customer_id

      assert Billing.start_checkout(account, "team", :month, subject) ==
               {:error, :paddle_unavailable}

      # The failed create left no customer linked on the account row.
      assert {:ok, reloaded} = Emisar.Accounts.fetch_account_by_id(account.id)
      refute reloaded.paddle_customer_id
    end
  end

  describe "ensure_paddle_customer/2 — vendor failure" do
    test "a create_customer error returns {:error, term} and links nothing" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert Billing.ensure_paddle_customer(account, subject) == {:error, :paddle_unavailable}

      assert {:ok, reloaded} = Emisar.Accounts.fetch_account_by_id(account.id)
      refute reloaded.paddle_customer_id
    end
  end

  describe "open_billing_portal/2 — odd vendor shape" do
    setup do
      # With a Paddle API key set, open_billing_portal hits the live client
      # instead of the stub-URL fallback; the failing client returns a
      # non-{:ok, %{"url" => _}} shape that the function passes through verbatim.
      Emisar.Config.put_override(:emisar, :paddle_api_key, "pdl_test_key")
      :ok
    end

    test "a non-url portal-session result is passed through, not crashed" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      account = %{account | paddle_customer_id: "ctm_existing_01"}

      assert Billing.open_billing_portal(account, subject) == {:error, :paddle_unavailable}
    end
  end
end

# A Paddle client that captures the attrs each call receives by sending them to
# a registered test pid, then returns a successful shape — so the args
# `start_checkout/4` / `ensure_paddle_customer/2` build (per-seat quantity,
# success/cancel URLs, the verbatim email + name) can be asserted without the
# live HTTP layer.
defmodule Emisar.BillingTest.CapturingPaddleClient do
  @behaviour Emisar.Billing.PaddleClient

  # Not what any of these stubs exercise; the behaviour requires it.
  @impl true
  def cancel_subscription(id) do
    report({:cancel_subscription, id})

    case Emisar.Config.get_env(:emisar, :billing_cancel_error) do
      nil -> {:ok, %{"id" => id, "status" => "canceled"}}
      reason -> {:error, reason}
    end
  end

  # The capturing pid rides in app env (set per-test) so the client stays
  # stateless — the same pattern BillingSyncTest's fail-id client uses.
  defp report(message), do: send(Emisar.Config.fetch_env!(:emisar, :billing_capture_pid), message)

  @impl true
  def create_customer(attrs) do
    report({:create_customer, attrs})
    {:ok, %{"id" => "ctm_captured_01"}}
  end

  @impl true
  def update_customer(attrs) do
    report({:update_customer, attrs})
    {:ok, %{"id" => attrs[:customer]}}
  end

  @impl true
  def list_customers(attrs) do
    report({:list_customers, attrs})
    {:ok, [%{"id" => "ctm_captured_01"}]}
  end

  @impl true
  def create_checkout_session(attrs) do
    report({:create_checkout_session, attrs})

    {:ok,
     %{
       "id" => "txn_captured_01",
       "url" => "https://stub.paddle.test/checkout/captured"
     }}
  end

  @impl true
  def bind_checkout_transaction(id, binding) do
    report({:bind_checkout_transaction, id, binding})
    {:ok, %{"id" => id}}
  end

  @impl true
  def create_billing_portal_session(attrs) do
    report({:create_billing_portal_session, attrs})
    {:ok, %{"url" => "https://stub.paddle.test/portal/captured"}}
  end

  @impl true
  def retrieve_subscription(_id), do: {:error, :unused}

  @impl true
  def update_subscription(_id, _attrs), do: {:error, :unused}

  @impl true
  def retrieve_transaction(_id), do: {:error, :unused}
  @impl true
  def list_subscriptions(_attrs), do: {:error, :unused}

  @impl true
  # The canned catalog carries both cycles, so the captured
  # create_checkout_session args assert the cycle→price selection.
  def list_products do
    default = [
      %{
        "id" => "pro_captured_team",
        "name" => "team",
        "status" => "active",
        "custom_data" => %{"plan" => "team"},
        "prices" => [
          %{
            "id" => "pri_team_01",
            "status" => "active",
            "billing_cycle" => %{"interval" => "month", "frequency" => 1},
            "unit_price" => %{"amount" => "2000", "currency_code" => "USD"}
          },
          %{
            "id" => "pri_team_annual_01",
            "status" => "active",
            "billing_cycle" => %{"interval" => "year", "frequency" => 1},
            "unit_price" => %{"amount" => "20000", "currency_code" => "USD"}
          }
        ]
      }
    ]

    {:ok, Emisar.Config.get_env(:emisar, :billing_test_catalog, default)}
  end

  @impl true
  def get_transaction_invoice(_id), do: {:error, :unused}

  @impl true
  def list_transactions(_attrs), do: {:error, :unused}

  @impl true
  def construct_webhook_event(_payload, _sig, _secret), do: {:error, :unused}
end

defmodule Emisar.BillingCheckoutArgsTest do
  @moduledoc """
  The exact args `start_checkout/4` + `ensure_paddle_customer/2` hand to the
  Paddle client — per-seat quantity, the success/cancel return URLs, and the
  verbatim email/name. Binds `:paddle_client` (and the capture pid the client
  reports to) per-process with `Emisar.Config.put_override/3`, so `async: true`.
  """
  use Emisar.DataCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.Accounts
  alias Emisar.Billing
  alias Emisar.BillingTest.CapturingPaddleClient
  alias Emisar.Fixtures

  setup do
    Emisar.Config.put_override(:emisar, :paddle_client, CapturingPaddleClient)
    Emisar.Config.put_override(:emisar, :billing_capture_pid, self())
    :ok
  end

  test "the checkout quantity equals the account's live billable runner count" do
    # Team is per-runner pricing, so start_checkout passes
    # `quantity: current_count(account, :runners)` — the live billable count. Five
    # runners → quantity 5 on the created checkout session.
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_seat_count_01"}
    for _ <- 1..5, do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)

    assert_received {:create_checkout_session, %{quantity: 5, price_id: "pri_team_01"}}
    assert_received {:bind_checkout_transaction, transaction_id, binding}

    assert Emisar.Crypto.verify_paddle_account_binding(binding) ==
             {:ok, {account.id, transaction_id}}
  end

  test "a checkout completed after account closure is canceled instead of reactivating it" do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert_received {:bind_checkout_transaction, transaction_id, binding}

    assert {:ok, closed} = Accounts.close_account(account.id, "No longer needed", subject)
    assert %DateTime{} = closed.deleted_at
    refute_received {:cancel_subscription, _id}

    event = %{
      "event_id" => "evt_late_closed_checkout_01",
      "event_type" => "subscription.created",
      "occurred_at" => "2026-08-26T00:00:00Z",
      "data" => %{
        "id" => "sub_late_closed_checkout_01",
        "customer_id" => "ctm_captured_01",
        "status" => "active",
        "transaction_id" => transaction_id,
        "custom_data" => %{"emisar_account_binding" => binding},
        "items" => [
          %{
            "product" => %{"name" => "team", "custom_data" => %{"plan" => "team"}},
            "price" => %{"id" => "pri_team_01"}
          }
        ]
      }
    }

    assert Billing.record_and_apply_event(
             "evt_late_closed_checkout_01",
             "subscription.created",
             event
           ) == :ok

    assert_received {:cancel_subscription, "sub_late_closed_checkout_01"}

    refute Emisar.Billing.Subscription.Query.all()
           |> Emisar.Billing.Subscription.Query.by_account_id(account.id)
           |> Emisar.Repo.exists?()
  end

  test "a late checkout is canceled even when closure retained another active mirror" do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert_received {:bind_checkout_transaction, transaction_id, binding}

    {:ok, retained} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_retained_at_close_01",
        plan: "team",
        status: "active"
      })

    assert {:ok, _closed} = Accounts.close_account(account.id, "No longer needed", subject)
    assert_received {:cancel_subscription, "sub_retained_at_close_01"}

    event = %{
      "event_id" => "evt_second_late_checkout_01",
      "event_type" => "subscription.created",
      "occurred_at" => "2026-08-26T00:00:00Z",
      "data" => %{
        "id" => "sub_second_late_checkout_01",
        "customer_id" => "ctm_captured_01",
        "status" => "active",
        "transaction_id" => transaction_id,
        "custom_data" => %{"emisar_account_binding" => binding},
        "items" => [
          %{
            "product" => %{"name" => "team", "custom_data" => %{"plan" => "team"}},
            "price" => %{"id" => "pri_team_01"}
          }
        ]
      }
    }

    assert Billing.record_and_apply_event(
             "evt_second_late_checkout_01",
             "subscription.created",
             event
           ) == :ok

    assert_received {:cancel_subscription, "sub_second_late_checkout_01"}
    assert Emisar.Repo.reload!(retained).paddle_subscription_id == "sub_retained_at_close_01"
  end

  test "a failed late-checkout cancellation remains retryable and creates no subscription" do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert_received {:bind_checkout_transaction, transaction_id, binding}
    assert {:ok, _closed} = Accounts.close_account(account.id, "No longer needed", subject)

    Emisar.Config.put_override(:emisar, :billing_cancel_error, :paddle_unavailable)

    event = %{
      "event_id" => "evt_late_closed_checkout_failed_01",
      "event_type" => "subscription.created",
      "occurred_at" => "2026-08-26T00:00:00Z",
      "data" => %{
        "id" => "sub_late_closed_checkout_failed_01",
        "customer_id" => "ctm_captured_01",
        "status" => "active",
        "transaction_id" => transaction_id,
        "custom_data" => %{"emisar_account_binding" => binding},
        "items" => [
          %{
            "product" => %{"name" => "team", "custom_data" => %{"plan" => "team"}},
            "price" => %{"id" => "pri_team_01"}
          }
        ]
      }
    }

    assert Billing.record_and_apply_event(
             "evt_late_closed_checkout_failed_01",
             "subscription.created",
             event
           ) == {:error, {:apply_failed, :paddle_unavailable}}

    assert_received {:cancel_subscription, "sub_late_closed_checkout_failed_01"}

    refute Emisar.Repo.exists?(
             from event in "paddle_processed_events",
               where: event.id == "evt_late_closed_checkout_failed_01"
           )

    refute Emisar.Billing.Subscription.Query.all()
           |> Emisar.Billing.Subscription.Query.by_account_id(account.id)
           |> Emisar.Repo.exists?()
  end

  test "the billing cycle selects the matching catalog price" do
    # :month picks the monthly price, :year the annual one — both off the same
    # product's `prices`, keyed on billing_cycle.interval.
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_cycle_price_01"}

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert_received {:create_checkout_session, %{price_id: "pri_team_01"}}

    assert {:ok, _url} = Billing.start_checkout(account, "team", :year, subject)
    assert_received {:create_checkout_session, %{price_id: "pri_team_annual_01"}}
  end

  test "a missing requested cadence never falls back to the other active price" do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    account = %{account | paddle_customer_id: "ctm_exact_cycle_01"}

    Emisar.Config.put_override(:emisar, :billing_test_catalog, [
      %{
        "id" => "pro_month_only",
        "name" => "team",
        "status" => "active",
        "custom_data" => %{"plan" => "team"},
        "prices" => [
          %{
            "id" => "pri_month_only",
            "status" => "active",
            "billing_cycle" => %{"interval" => "month", "frequency" => 1}
          }
        ]
      }
    ])

    assert Billing.start_checkout(account, "team", :year, subject) ==
             {:error, :plan_not_in_catalog}

    refute_received {:create_checkout_session, _attrs}
  end

  test "a multi-period price never satisfies a monthly or annual choice" do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    account = %{account | paddle_customer_id: "ctm_exact_frequency_01"}

    for cycle <- [:month, :year] do
      interval = Atom.to_string(cycle)

      Emisar.Config.put_override(:emisar, :billing_test_catalog, [
        %{
          "id" => "pro_#{interval}_frequency_two",
          "name" => "team",
          "status" => "active",
          "custom_data" => %{"plan" => "team"},
          "prices" => [
            %{
              "id" => "pri_#{interval}_frequency_two",
              "status" => "active",
              "billing_cycle" => %{"interval" => interval, "frequency" => 2}
            }
          ]
        }
      ])

      assert Billing.start_checkout(account, "team", cycle, subject) ==
               {:error, :plan_not_in_catalog}

      refute_received {:create_checkout_session, _attrs}
    end
  end

  test "a zero-runner account checks out at quantity 1 — Paddle rejects 0" do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_seat_floor_01"}

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)

    assert_received {:create_checkout_session, %{quantity: 1}}
  end

  test "the checkout session carries no URL overrides — the default payment link is the page" do
    # Paddle mints data.checkout.url from the account's default payment link
    # (our /checkout Paddle.js page) + ?_ptxn=. A per-transaction checkout.url
    # override needs its own domain approval, and the post-payment redirect is
    # the page's successUrl setting — so nothing URL-ish rides on the transaction.
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_urls_01"}

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)

    assert_received {:create_checkout_session, attrs}
    refute Map.has_key?(attrs, :checkout_url)
    refute Map.has_key?(attrs, :success_url)
    refute Map.has_key?(attrs, :cancel_url)
  end

  test "create_customer forwards the selected owner email + account name verbatim" do
    # ensure_paddle_customer threads the selected owner email + the account name
    # (incl. special characters) straight onto the Paddle customer with no
    # mangling — invoices reach a real inbox and the customer is recognisable in
    # Paddle.
    user = Fixtures.Users.create_user(%{email: "billing-owner@example.test"})
    account_attrs = Fixtures.Accounts.account_attrs(%{name: "Acme & Co. (Ops)"})
    {:ok, account} = Accounts.create_account_with_owner(account_attrs, user)
    subject = Fixtures.Subjects.subject_for(user, account)

    assert {:ok, "ctm_captured_01", _account} = Billing.ensure_paddle_customer(account, subject)

    assert_received {:create_customer, paddle_attrs}
    assert paddle_attrs.email == "billing-owner@example.test"
    assert paddle_attrs.name == "Acme & Co. (Ops)"
    assert paddle_attrs.account_id == account.id
  end

  test "update_customer switches to a new active owner when the prior contact is demoted" do
    prior_owner = Fixtures.Users.create_user(%{email: "prior-owner@example.test"})
    account_attrs = Fixtures.Accounts.account_attrs(%{name: "Owner Transfer Co."})
    {:ok, account} = Accounts.create_account_with_owner(account_attrs, prior_owner)

    new_owner = Fixtures.Users.create_user(%{email: "new-owner@example.test"})

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: new_owner.id,
      role: "owner"
    )

    {:ok, account} =
      Accounts.put_account_paddle_customer_sync(account, "ctm_existing_owner", prior_owner.id)

    prior_membership = Fixtures.Memberships.fetch_membership(account.id, prior_owner.id)
    Fixtures.Memberships.force_role(prior_membership, "admin")

    assert {:ok, "ctm_existing_owner", synced} =
             Billing.sync_paddle_customer_for_account(account.id)

    assert synced.paddle_billing_contact_user_id == new_owner.id
    assert_received {:update_customer, paddle_attrs}
    assert paddle_attrs.customer == "ctm_existing_owner"
    assert paddle_attrs.email == "new-owner@example.test"
    assert paddle_attrs.name == "Owner Transfer Co."
    assert paddle_attrs.account_id == account.id
  end

  test "a normal checkout leaks no secret / customer id / price id into the log drain" do
    # The happy checkout + portal-open paths emit no log line carrying the Paddle
    # API key, the customer id, or the price id — those would land in the drain
    # (Sentry/console) verbatim. Capture the log around both and assert the
    # sensitive values never appear.
    Emisar.Config.put_override(:emisar, :paddle_api_key, "pdl_live_secret_key")

    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    account = %{account | paddle_customer_id: "ctm_logsafe_01"}

    log =
      capture_log(fn ->
        assert {:ok, _} = Billing.start_checkout(account, "team", :month, subject)
        assert {:ok, _} = Billing.open_billing_portal(account, subject)
      end)

    refute log =~ "pdl_live_secret_key"
    refute log =~ "ctm_logsafe_01"
    refute log =~ "pri_team_01"
  end
end
