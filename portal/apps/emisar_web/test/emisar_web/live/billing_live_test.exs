defmodule EmisarWeb.BillingLiveTest do
  @moduledoc """
  The billing page (`/app/settings/billing`). The billing *context* is
  tested separately; this covers the web surface that gates real money:

    * an owner sees the plan + usage and the checkout/portal controls,
    * an owner's "upgrade" event starts checkout and redirects to the
      returned (stub) URL,
    * a viewer sees no upgrade controls and a crafted "upgrade" event is
      refused by the `:manage_billing` gate (no redirect).
  """
  use EmisarWeb.ConnCase, async: true

  defp downgrade_to(user, role) when is_binary(role) do
    {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Fixtures.Memberships.force_role(membership, role)
  end

  describe "as an owner" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "renders the current plan and usage meters", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Free plan strip + the two usage meters.
      assert html =~ "Current plan"
      assert html =~ "Free"
      assert html =~ "Runners"
      assert html =~ "Team members"
      # Owner sees the upgrade CTA (viewers don't — asserted below).
      assert html =~ "Upgrade to Team"
    end

    test "from a paid plan a lower plan reads as a Downgrade, never 'Upgrade to Free'", %{
      conn: conn,
      account: account
    } do
      insert_subscription(account, "active")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # On Team, Free is below — a downgrade, routed to the Paddle portal
      # (manage_billing), never a mislabeled "Upgrade to Free" checkout.
      assert html =~ "Downgrade to Free"
      refute html =~ "Upgrade to Free"
      refute html =~ ~s(phx-value-plan="free")
    end

    test "the upgrade event starts checkout and redirects externally", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The owner is offered the upgrade control (the strip CTA + the
      # team plan card both carry it).
      assert has_element?(lv, "button[phx-click='upgrade'][phx-value-plan='team']")

      # `Billing.start_checkout/4` resolves the price from the (stub) catalog
      # and returns the checkout URL; the LV redirects externally to it. Drive
      # the event by name to avoid matching the two identical "team" buttons.
      assert {:error, {:redirect, %{to: url}}} =
               render_click(lv, "upgrade", %{"plan" => "team", "cycle" => "month"})

      assert url =~ "stub.paddle.test/checkout"
    end

    test "the annual toggle swaps the plan card price and threads the cycle to checkout", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Default is monthly; flipping to annual re-renders the Team card at the
      # per-year price with its savings note.
      assert render(lv) =~ "$20 / runner / month"

      annual = render_click(lv, "set_cycle", %{"cycle" => "year"})
      assert annual =~ "$200 / runner / year"
      assert annual =~ "2 months free"
      assert has_element?(lv, "button[phx-value-cycle='year'][phx-click='upgrade']")

      # An annual upgrade still starts checkout (price selection is asserted in
      # billing_test's capturing client).
      assert {:error, {:redirect, %{to: url}}} =
               render_click(lv, "upgrade", %{"plan" => "team", "cycle" => "year"})

      assert url =~ "stub.paddle.test/checkout"
    end

    test "the enterprise card surfaces contact-sales, not checkout", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      html =
        lv
        |> element("button", "Contact sales")
        |> render_click()

      assert html =~ "We&#39;ll be in touch" or html =~ "We'll be in touch"
      # Still on the page — no external redirect for the sales-led tier.
      assert html =~ "Current plan"
    end

    test "an enterprise account can't self-downgrade — it surfaces contact-support", %{
      conn: conn,
      account: account
    } do
      insert_subscription_with(account, %{plan: "enterprise", status: "active"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The special-state notice names the custom plan and carries the one real
      # action — email support (a prefilled mailto), not a self-serve control.
      assert html =~ "Custom Enterprise plan"
      assert html =~ "mailto:support@emisar.dev"

      # No self-serve downgrade off a custom plan: the lower tiers read "Contact
      # support to switch", never a "Downgrade to …" routing to a Paddle portal
      # this account has no customer in.
      assert html =~ "Contact support to switch"
      refute html =~ "Downgrade to"
    end
  end

  describe "usage meter + plan display" do
    test "a Free account at the runner ceiling colours the meter amber, never rose", %{
      conn: conn
    } do
      # 3/3 billable runners on Free is 100% utilisation — a plan fact, not a
      # failure: amber says "look at your limits"; rose is reserved for a hard
      # lockout that the clamped pct can never render.
      {conn, _user, account} = register_and_log_in(conn)
      for _ <- 1..3, do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "/ 3"
      assert html =~ ~s(class="h-full transition-[width] bg-amber-400")
      refute html =~ ~s(class="h-full transition-[width] bg-rose-400")
    end

    test "a Team account at 80% of its runner cap colours the meter amber", %{conn: conn} do
      # 80/100 billable runners on Team is 80% utilisation → the runners bar uses
      # the amber `usage_class` (≥80% and <100%), the pre-ceiling warning colour.
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "active")

      for _ <- 1..80,
          do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "/ 100"
      assert html =~ ~s(class="h-full transition-[width] bg-amber-400")
      refute html =~ ~s(class="h-full transition-[width] bg-rose-400")
    end

    test "the hero CTA offers only the next priced tier, never an enterprise upgrade", %{
      conn: conn
    } do
      # On Free the only checkoutable step up is Team, so the hero CTA reads
      # "Upgrade to Team" — never "Upgrade to Enterprise" (enterprise is
      # contact-sales, surfaced by its own card, not a checkout CTA).
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Upgrade to Team"
      refute html =~ "Upgrade to Enterprise"
    end

    test "a legacy/unknown plan name degrades to free-tier display", %{conn: conn} do
      # `plan("legacy-pro")` is nil → plan_def falls back to plan("free"), so the
      # strip shows the Free name + the three plan cards still render. A dropped
      # plan must never 500 the billing page.
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription_with(account, %{plan: "legacy-pro", status: "active"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # plan_def.name degrades to "Free"; the page renders, plans still listed.
      assert html =~ "Current plan"
      assert html =~ "Free"
      assert html =~ "Team"
      assert html =~ "Enterprise"
      # No banner — "active" is healthy — and no crash on the unknown plan key.
      refute html =~ "Payment past due"
    end

    test "an enterprise account shows a Custom total and Unlimited meters", %{conn: conn} do
      # Enterprise has monthly_price_cents nil → monthly_total_cents nil →
      # format_total(nil) renders "Custom" (not a cents figure). Runner + member
      # limits are :unlimited → limit_label "Unlimited" and usage_pct nil, so the
      # meters render the gradient placeholder bar with no width/percentage.
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription_with(account, %{plan: "enterprise", status: "active"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Enterprise"
      # The plan strip shows "Custom/mo", never a "$…" total for the enterprise tier.
      assert html =~ "Custom/mo"
      # Both meters read "/ Unlimited" (no numeric ceiling).
      assert html =~ "/ Unlimited"
      # usage_pct is nil for an :unlimited limit → NO progress bar at all (a bar
      # with no cap to fill against is meaningless); just the "N / Unlimited" count.
      refute html =~ "style=\"width:"
    end

    test "dead cycle-note fields (cancel_at/trial_end) render nothing", %{conn: conn} do
      # No prod path writes cancel_at_period_end/trial_end, and the apply path
      # leaves current_period_start null. With status set but those columns at
      # their defaults, none of the cycle-note chips render.
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription_with(account, %{plan: "team", status: "active"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Cancels on"
      refute html =~ "Trial ends"
      # current_period_end is also unset here, so even the "Next charge" note is absent.
      refute html =~ "Next charge"
    end
  end

  describe "manage subscription" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "an owner with a Paddle customer is redirected to the portal", %{
      conn: conn,
      account: account
    } do
      # With a customer attached and no Paddle key configured (test default),
      # open_billing_portal returns the stub portal URL and the LV redirects to it.
      account = attach_customer(account, "ctm_portal_01")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The "Manage subscription" control is present once a customer exists…
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage subscription")

      # …and clicking it redirects out to the (stub) portal URL.
      assert {:error, {:redirect, redirect}} = render_click(lv, "manage_billing", %{})
      url = redirect[:to] || redirect[:external]
      assert is_binary(url) and url =~ "stub-portal"
    end

    test "a manage event on a no-customer account flashes :no_customer, no redirect", %{
      conn: conn,
      account: account
    } do
      # On an account with no paddle_customer_id, open_billing_portal short-circuits
      # to {:error, :no_customer} BEFORE any PaddleClient call, so the handler shows
      # the "upgrade first" flash and stays on the page (no redirect). The flash —
      # not a portal URL — is the proof the vendor was never reached.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # No customer attached → no Manage control rendered; push the event directly.
      refute has_element?(lv, "button[phx-click='manage_billing']")

      html = render_hook(lv, "manage_billing", %{})
      assert html =~ "upgrade to a paid plan first"
    end

    test "an admin pushing a crafted manage event is refused — flash, no redirect", %{
      conn: conn,
      user: user,
      account: account
    } do
      # manage_billing is owner-only. An admin (who can VIEW billing) crafting the
      # manage_billing event is double-gated: Permissions.gated denies it in the LV
      # before the context is even called, so the result is a permission flash and
      # no portal redirect. (Customer attached, to prove the gate — not the
      # no-customer branch — is what refuses.)
      downgrade_to(user, "admin")
      account = attach_customer(account, "ctm_admin_manage_01")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      html = render_hook(lv, "manage_billing", %{})
      assert html =~ "have permission to do that."
    end

    test "the Manage control is hidden for a viewer even with a customer attached", %{
      conn: conn,
      user: user,
      account: account
    } do
      # The Manage-subscription button is gated on subject_can_manage_billing? AND a
      # customer being present. A viewer has a customer but not the permission, so
      # the button is suppressed (the owner-only affordance never renders for them).
      downgrade_to(user, "viewer")
      account = attach_customer(account, "ctm_viewer_manage_01")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Page renders (a viewer can view billing) but the manage affordance is gone.
      assert html =~ "Current plan"
      refute has_element?(lv, "button[phx-click='manage_billing']")
    end
  end

  describe "as a viewer" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "no upgrade controls render", %{conn: conn, user: user, account: account} do
      downgrade_to(user, "viewer")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The plan/usage is visible to everyone who can view billing…
      assert html =~ "Current plan"
      # …but the owner-only upgrade CTA + per-card upgrade buttons are
      # replaced with the read-only affordance.
      refute html =~ "Upgrade to Team"
      assert html =~ "Owners only"
    end

    test "a crafted upgrade event is refused — flash, no redirect", %{
      conn: conn,
      user: user,
      account: account
    } do
      downgrade_to(user, "viewer")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The button isn't rendered for a viewer, so push the event
      # directly (IL-15: the handler must gate, not just the UI). A
      # denial returns {:noreply, ...} with a flash — no redirect — so
      # render_hook returns HTML, not an {:error, {:redirect, …}}.
      html = render_hook(lv, "upgrade", %{"plan" => "team"})

      assert html =~ "have permission to do that."
    end
  end

  describe "subscription health banner" do
    test "a past_due subscription shows the rose payment banner + a manage action", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "past_due")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Payment past due"
      assert html =~ "update your card"
      # The owner can fix it — the banner surfaces the billing portal.
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage billing")
    end

    test "a canceled subscription shows the amber banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "canceled")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Subscription canceled"
      # Honest copy: nothing gates on subscription status, so the banner must
      # not imply lost access / paid features.
      refute html =~ "paid features"
    end

    test "a healthy account shows no failure banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Payment past due"
      refute html =~ "Subscription canceled"
    end

    test "a paused subscription shows the amber paused banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "paused")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Subscription paused"
      assert html =~ "Resume it from the billing portal"
      # Amber FYI, not the rose payment-failure tone.
      refute html =~ "Payment past due"
    end

    test "an unknown/unmodeled status shows no banner (don't alarm)", %{conn: conn} do
      # subscription_alert/1 only models past_due/paused/canceled; anything else
      # → nil → no banner. Paddle owns the status value space, so a state we can't
      # explain must not raise a scary banner.
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "some_unmodeled_status")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Payment past due"
      refute html =~ "Subscription paused"
      refute html =~ "Subscription canceled"
      # The page still renders fine for the unmodeled status.
      assert html =~ "Current plan"
    end

    test "the banner copy nudges to fix payment, never implying lost access", %{conn: _conn} do
      # emisar never gates features on subscription status, so each modeled status
      # gets an advisory payment/resubscribe nudge ONLY — the copy must never imply
      # access is lost (a promise the code doesn't keep). Assert the known advisory
      # body for each status, plus the absence of the specific lost-access
      # phrasings that would be a regression. (Scoped to multi-word phrases —
      # single words like "lost" appear in unrelated page chrome.)
      cases = [
        {"past_due", "update your card so the next charge goes through"},
        {"paused", "Resume it from the billing portal"},
        {"canceled", "Resubscribe from billing to start a new subscription"}
      ]

      for {status, advisory_body} <- cases do
        {conn, _user, account} = register_and_log_in(build_conn())
        insert_subscription(account, status)

        {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

        # The banner shows its advisory body…
        assert html =~ advisory_body
        # …and never a lost-access / locked-out promise.
        refute html =~ "no longer have access"
        refute html =~ "access has been"
        refute html =~ "paid features"
        refute html =~ "lost access"
      end
    end

    test "a viewer on a past_due account sees the banner without the manage CTA", %{conn: conn} do
      # The banner renders for everyone who can view billing, but its :cta slot is
      # gated on subject_can_manage_billing? — a viewer sees the nudge with no
      # Manage-billing button to act on.
      {conn, user, account} = register_and_log_in(conn)
      downgrade_to(user, "viewer")
      insert_subscription(account, "past_due")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Payment past due"
      refute has_element?(lv, "button[phx-click='manage_billing']")
    end
  end

  defp insert_subscription(account, status) do
    {:ok, subscription} =
      %{account_id: account.id, plan: "team", status: status}
      |> Emisar.Billing.Subscription.Changeset.upsert()
      |> Emisar.Repo.insert()

    subscription
  end

  # A subscription with arbitrary fields (plan/status/cycle-note columns), for
  # the display-degradation + banner edge cases.
  defp insert_subscription_with(account, attrs) do
    {:ok, subscription} =
      attrs
      |> Map.put(:account_id, account.id)
      |> Emisar.Billing.Subscription.Changeset.upsert()
      |> Emisar.Repo.insert()

    subscription
  end

  defp attach_customer(account, customer_id) do
    {:ok, account} =
      account
      |> Ecto.Changeset.change(paddle_customer_id: customer_id)
      |> Emisar.Repo.update()

    account
  end
end
