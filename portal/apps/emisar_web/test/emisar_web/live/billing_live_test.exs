defmodule EmisarWeb.BillingLiveTest.InvoicePaddleClient do
  @moduledoc false
  # Override only invoice reads: errors and oversized result sets must not
  # change checkout/portal behavior elsewhere on the page.
  @behaviour Emisar.Billing.PaddleClient
  @impl true
  defdelegate cancel_checkout_transaction(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_checkout_transactions(attrs), to: Emisar.Billing.PaddleClient.Stub

  alias Emisar.Billing.PaddleClient.Stub

  @impl true
  defdelegate cancel_subscription(id), to: Stub
  @impl true
  defdelegate create_customer(attrs), to: Stub
  @impl true
  defdelegate update_customer(attrs), to: Stub
  @impl true
  defdelegate list_customers(attrs), to: Stub
  @impl true
  defdelegate create_checkout_session(attrs), to: Stub
  @impl true
  defdelegate bind_checkout_transaction(id, binding), to: Stub
  @impl true
  defdelegate create_billing_portal_session(attrs), to: Stub
  @impl true
  defdelegate retrieve_subscription(id), to: Stub
  @impl true
  defdelegate update_subscription(id, attrs), to: Stub
  @impl true
  defdelegate retrieve_transaction(id), to: Stub
  @impl true
  defdelegate list_subscriptions(attrs), to: Stub
  @impl true
  defdelegate list_products, to: Stub
  @impl true
  defdelegate get_transaction_invoice(id), to: Stub
  @impl true
  defdelegate construct_webhook_event(payload, sig, secret), to: Stub

  @impl true
  def list_transactions(attrs) do
    if owner = Emisar.Config.get_env(:emisar, :billing_test_invoice_owner) do
      send(owner, {:invoice_request, attrs})
    end

    Emisar.Config.get_env(:emisar, :billing_test_invoice_result) || {:error, :paddle_unavailable}
  end
end

defmodule EmisarWeb.BillingLiveTest do
  @moduledoc """
  The billing page (`/app/settings/billing`). The billing *context* is
  tested separately; this covers the web surface that gates real money:

    * an owner sees the plan + usage and the checkout/portal controls,
    * an owner's "upgrade" event starts checkout and redirects to the
      returned (stub) URL,
    * a billing manager gets the same money controls (the role holds
      `manage_billing`),
    * a viewer sees no upgrade controls and a crafted "upgrade" event is
      refused by the `:manage_billing` gate (no redirect),
    * the invoice history loads async off the mount path, with explicit
      loading and failed-with-retry states.
  """
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.BillingIntent
  alias EmisarWeb.BillingLiveTest.InvoicePaddleClient

  defp downgrade_to(user, role) when is_binary(role) do
    {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Fixtures.Memberships.force_role(membership, role)
  end

  describe "as an owner" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, account: account, user: user}
    end

    test "renders the current plan and usage without offering Free product support", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Free plan strip + the two usage meters.
      assert html =~ "Current plan"
      assert html =~ "Free"
      assert html =~ "Runners"
      assert html =~ "Team members"
      assert html =~ "Billing docs"
      refute html =~ "Compare plans"
      assert html =~ "See what your plan includes and how much you"
      assert has_element?(lv, "#billing-usage", "/ 3")
      assert has_element?(lv, "#billing-usage", "7 days")
      assert html =~ "Up to 100 runners"
      assert html =~ "Unlimited runners"
      refute html =~ "$0/mo"
      refute has_element?(lv, "#billing-support")
      refute has_element?(lv, "nav a[href^='mailto:support@emisar.dev']")

      refute html =~
               "Contact us for general support, billing help, plan changes, or cancellation."

      # Owner sees the upgrade CTA (viewers don't — asserted below).
      assert html =~ "Upgrade to Team"
      # The Enterprise plan card carries the same benefit the pricing page promises.
      assert html =~ "Slack and email support"

      assert has_element?(
               lv,
               "#billing-offer-team button[phx-click='upgrade']",
               "Upgrade to Team"
             )

      assert has_element?(
               lv,
               "#billing-offer-enterprise a[href^='mailto:sales@emisar.dev']",
               "Contact sales"
             )

      assert has_element?(lv, "#billing-offer-team button[phx-click='set_cycle']", "Annual")
      refute has_element?(lv, "#billing-offer-enterprise button[phx-click='set_cycle']")
      refute has_element?(lv, "#billing-offer-free")

      assert has_element?(
               lv,
               "#billing-offer-team",
               "Estimated total: $20.00/month for 1 billable runner"
             )
    end

    test "a lower plan routes an existing subscription to Manage billing", %{
      conn: conn,
      account: account
    } do
      attach_customer(account, "ctm_managed_team")

      insert_subscription_with(account, %{
        plan: "team",
        status: "active",
        paddle_subscription_id: "sub_managed_team"
      })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Changes and downgrades remain reachable without a card for each tier.
      assert html =~ "Manage billing"
      assert has_element?(lv, "#billing-offer-enterprise a", "Contact sales")
      refute has_element?(lv, "#billing-offer-team")
      refute has_element?(lv, "button[phx-click='set_cycle']")
      refute html =~ "Downgrade to Free"
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

      assert has_element?(
               lv,
               "#billing-offer-team",
               "Estimated total: $200.00/year for 1 billable runner"
             )

      assert has_element?(lv, "button[phx-value-cycle='year'][phx-click='upgrade']")

      # An annual upgrade still starts checkout (price selection is asserted in
      # billing_test's capturing client).
      assert {:error, {:redirect, %{to: url}}} =
               render_click(lv, "upgrade", %{"plan" => "team", "cycle" => "year"})

      assert url =~ "stub.paddle.test/checkout"
    end

    for {state, message} <- [
          creating: "We&#39;re confirming your checkout.",
          legacy: "We couldn&#39;t confirm an earlier checkout.",
          paid: "We&#39;re confirming your payment and subscription.",
          retirement: "We&#39;re confirming the cancellation of an earlier subscription."
        ] do
      test "#{state} checkout gives an actionable pending state without another POST", %{
        conn: conn,
        account: account,
        user: user
      } do
        Fixtures.Billing.start_provider()
        subject = Fixtures.Subjects.subject_for(user, account)

        assert {:ok, _customer_id, account} =
                 Emisar.Billing.ensure_paddle_customer(account, subject)

        case unquote(state) do
          :creating ->
            Fixtures.Billing.create_checkout_intent(account)

          :legacy ->
            Fixtures.Billing.create_legacy_transaction(account)
            assert_received {:paddle, :create, _attrs, _caller}

          :paid ->
            assert {:ok, _url} = Emisar.Billing.start_checkout(account, "team", :month, subject)
            assert_received {:paddle, :bind, {transaction_id, _custom_data}, _caller}
            Fixtures.Billing.set_transaction(transaction_id, %{"status" => "paid"})
            assert_received {:paddle, :create, _attrs, _caller}

          :retirement ->
            transaction = Fixtures.Billing.create_legacy_transaction(account)
            subscription = Fixtures.Billing.complete_transaction(transaction["id"])
            Fixtures.Billing.create_retirement(account, subscription)
            assert_received {:paddle, :create, _attrs, _caller}
        end

        {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
        html = render_click(lv, "upgrade", %{"plan" => "team", "cycle" => "month"})
        assert html =~ unquote(message)
        assert html =~ "Try again shortly"
        assert has_element?(lv, "button[phx-click='upgrade'][phx-value-plan='team']")
        refute_received {:paddle, :create, _attrs, _caller}
      end
    end

    test "a signed annual Team choice is preselected but still requires Upgrade", %{
      conn: conn,
      account: account
    } do
      token = BillingIntent.sign("team", :year)

      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/settings/billing?billing_intent=#{token}")

      assert html =~ "Review Team for Test Co"
      assert html =~ "Annual billing is selected"
      assert html =~ "Nothing is charged until you confirm there"
      assert has_element?(lv, "#billing-offer-team", "Estimated total: $200.00/year")
      refute html =~ "most popular"
      assert has_element?(lv, "button[phx-value-cycle='year'][phx-click='upgrade']")
    end

    test "an invalid choice falls back to monthly without checkout context", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/settings/billing?billing_intent=forged")

      refute html =~ "Review Team for"
      refute html =~ "most popular"
      assert has_element?(lv, "button[phx-value-cycle='month'][phx-click='upgrade']")
    end

    test "crafted plan and cadence events fail closed without checkout", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert render_click(lv, "set_cycle", %{"cycle" => "weekly"}) =~
               "Unknown billing cycle"

      assert render_click(lv, "upgrade", %{"plan" => "enterprise", "cycle" => "month"}) =~
               "Unknown plan or billing cycle"

      assert render_click(lv, "upgrade", %{"plan" => "team", "cycle" => "weekly"}) =~
               "Unknown plan or billing cycle"
    end

    test "a Team choice does not show an upgrade prompt on an existing Team account", %{
      conn: conn,
      account: account
    } do
      insert_subscription(account, "active")
      token = BillingIntent.sign("team", :year)

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/settings/billing?billing_intent=#{token}")

      refute html =~ "Review Team for"
    end

    test "the enterprise card mails sales with account context, not checkout", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(lv, ~s|a[href^="mailto:sales@emisar.dev"]|, "Contact sales")
      assert html =~ "subject=Enterprise%20plan%20-%20Test%20Co"
      assert html =~ "Account%20ID%3A%20#{account.id}"
    end

    test "an enterprise account can't self-downgrade — it surfaces contact-support", %{
      conn: conn,
      account: account,
      user: user
    } do
      insert_subscription_with(account, %{plan: "enterprise", status: "active"})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Support-owned changes belong in the existing help rail, not another
      # callout repeating the plan's identity.
      refute html =~ "Custom plan"

      assert has_element?(
               lv,
               "#billing-support p",
               "Contact us for general support, billing help, plan changes, or cancellation."
             )

      refute html =~ "Questions about an invoice, your limits, or a custom plan?"
      assert html =~ "mailto:support@emisar.dev"
      assert html =~ "subject=Billing%20question%20-%20Test%20Co"
      assert html =~ "Account%20ID%3A%20#{account.id}"
      assert html =~ "User%3A%20#{String.replace(user.email, "@", "%40")}"

      # No self-serve downgrade off a custom plan: the lower tiers read "Contact
      # support", never a "Downgrade to …" routing to a Paddle portal
      # this account has no customer in.
      assert html =~ "Contact support"
      refute html =~ "Downgrade to"
      refute has_element?(lv, "#billing-upgrade-offers")
      refute has_element?(lv, "button[phx-click='set_cycle']")
    end
  end

  describe "plan-specific support" do
    for {plan, status, email?, slack?} <- [
          {"free", "active", false, false},
          {"team", "active", true, false},
          {"enterprise", "active", true, true},
          {"enterprise", "complimentary", true, true},
          {"enterprise", "canceled", false, false}
        ] do
      test "#{plan} / #{status} shows only its included support channels", %{conn: conn} do
        {conn, user, account} = register_and_log_in(conn)
        url = "https://workspace.slack.com/archives/C01234567"
        assert {:ok, _} = Emisar.Accounts.put_support_slack_url(account.id, url)
        Fixtures.Accounts.create_subscription(account, unquote(plan), status: unquote(status))

        {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")
        assert has_element?(lv, "#billing-support") == unquote(email?)

        assert has_element?(
                 lv,
                 "#billing-support a[href^='mailto:support@emisar.dev']",
                 "Email support"
               ) == unquote(email?)

        assert has_element?(lv, "#billing-support a[href='#{url}']", "Slack support") ==
                 unquote(slack?)

        assert has_element?(lv, "nav a[href='#{url}']") == unquote(slack?)
        assert has_element?(lv, "#mobile-nav a[href='#{url}']") == unquote(slack?)

        assert has_element?(lv, "nav a[href^='mailto:support@emisar.dev']", "Email support") ==
                 unquote(email?)

        if unquote(email?) do
          assert html =~ "subject=Support%20request%20-%20Test%20Co"
          assert html =~ "User%3A%20#{String.replace(user.email, "@", "%40")}"
        end

        if unquote(slack?) do
          assert has_element?(
                   lv,
                   "#billing-support a[href='#{url}'][target='_blank'][rel='noopener noreferrer']"
                 )
        else
          refute html =~ url
        end
      end
    end

    test "Enterprise without a configured channel offers email, not a broken Slack link", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "enterprise")
      other = Fixtures.Accounts.create_account(plan: "enterprise")
      other_url = "https://other.slack.com/archives/C98765432"
      assert {:ok, _} = Emisar.Accounts.put_support_slack_url(other.id, other_url)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")
      assert has_element?(lv, "#billing-support a", "Email support")
      refute has_element?(lv, "#billing-support a", "Slack support")
      refute html =~ other_url
    end

    test "Billing refreshes channel changes and removes support after downgrade", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "enterprise")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      url = "https://workspace.slack.com/archives/C01234567"

      assert {:ok, _} = Emisar.Accounts.put_support_slack_url(account.id, url)
      refresh_billing(lv)
      assert has_element?(lv, "#billing-support a[href='#{url}']")
      assert has_element?(lv, "nav a[href='#{url}']")

      assert {:ok, _} = Emisar.Accounts.put_support_slack_url(account.id, nil)
      refute refresh_billing(lv) =~ url
      assert has_element?(lv, "#billing-support a", "Email support")

      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")
      refresh_billing(lv)
      refute has_element?(lv, "#billing-support")
      refute has_element?(lv, "nav a[href^='mailto:support@emisar.dev']")
    end

    test "support navigation refreshes on other pages and ignores stale refresh ticks", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "enterprise")
      url = "https://workspace.slack.com/archives/C01234567"
      assert {:ok, _} = Emisar.Accounts.put_support_slack_url(account.id, url)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs")
      assert has_element?(lv, "nav a[href='#{url}']")

      assert {:ok, _} = Emisar.Accounts.put_support_slack_url(account.id, nil)
      attempt = :sys.get_state(lv.pid).socket.assigns.support_refresh
      send(lv.pid, {:refresh_nav_support, attempt})
      refute render(lv) =~ url
      assert has_element?(lv, "nav a", "Email support")
      next_attempt = :sys.get_state(lv.pid).socket.assigns.support_refresh
      send(lv.pid, {:refresh_nav_support, attempt})
      render(lv)
      assert :sys.get_state(lv.pid).socket.assigns.support_refresh == next_attempt

      Fixtures.Accounts.create_subscription(account, "enterprise",
        scheduled_change_action: "cancel",
        scheduled_change_effective_at: DateTime.add(DateTime.utc_now(), -1, :second)
      )

      send(lv.pid, {:refresh_nav_support, next_attempt})
      render(lv)
      refute has_element?(lv, "nav a[href^='mailto:support@emisar.dev']")
    end
  end

  describe "usage meter + plan display" do
    test "Team estimates use enabled runner quantity and update with the selected cycle", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      for _ <- 1..3, do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      |> Fixtures.Runners.disable_runner()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(
               lv,
               "#billing-offer-team",
               "Estimated total: $60.00/month for 3 billable runners"
             )

      render_click(lv, "set_cycle", %{"cycle" => "year"})

      assert has_element?(
               lv,
               "#billing-offer-team",
               "Estimated total: $600.00/year for 3 billable runners"
             )

      assert has_element?(lv, "#billing-current-plan", "$0")
    end

    test "features stay visible through price selection and a billing refresh", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(lv, "#billing-usage", "7 days")
      assert has_element?(lv, "section#billing-features", "Single sign-on (OIDC)")
      refute has_element?(lv, "#billing-features details")
      render_click(lv, "set_cycle", %{"cycle" => "year"})
      refresh_billing(lv)
      assert has_element?(lv, "section#billing-features", "Single sign-on (OIDC)")
      refute has_element?(lv, "#billing-features details")
    end

    test "Enterprise offers only benefits not already granted to Team", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      Fixtures.Accounts.create_subscription(account, "team",
        entitlements: %{
          "runners_limit" => "unlimited",
          "audit_retention_days" => 365,
          "features_scim_enabled?" => true
        }
      )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(lv, "#billing-features", "SCIM directory sync")
      refute has_element?(lv, "#billing-offer-enterprise", "SCIM directory sync")
      refute has_element?(lv, "#billing-offer-enterprise", "365-day audit retention")
      refute has_element?(lv, "#billing-offer-enterprise", "Unlimited runners")
      refute has_element?(lv, "#billing-offer-enterprise", "Everything in Team")
      refute has_element?(lv, "#billing-offer-enterprise", "Slack and email support")
      assert has_element?(lv, "#billing-offer-enterprise", "Slack support")
      assert has_element?(lv, "#billing-offer-enterprise", "Security and procurement review")
    end

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

    test "an unknown custom plan keeps its identity and management surface", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription_with(account, %{plan: "legacy-pro", status: "active"})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(lv, "#billing-current-plan", "Legacy-pro")
      assert has_element?(lv, "#billing-current-plan a", "Contact support")
      refute has_element?(lv, "#billing-upgrade-offers")
      refute has_element?(lv, "button[phx-click='set_cycle']")
      refute html =~ "Payment past due"
    end

    test "an unknown plan name is treated as sales-led, not as below Free", %{
      conn: conn
    } do
      # The only way to hold a slug this build doesn't know is a custom deal minted
      # in Paddle, so it ranks ABOVE the self-serve tiers. Ranking it below Free
      # inverted every card comparison: the highest-value customer we have was
      # offered "Upgrade to Free" and shown Team's upsell chip.
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription_with(account, %{plan: "enterprise-trial", status: "active"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Upgrade to Free"
      refute html =~ "Upgrade to Team"
      refute html =~ "most popular"

      # Same treatment the literal "enterprise" plan gets: the one real action.
      refute html =~ "Custom plan"

      assert html =~
               "Contact us for general support, billing help, plan changes, or cancellation."

      assert html =~ "Contact support"
    end

    test "an enterprise account shows a Custom total and Unlimited meters", %{conn: conn} do
      # Enterprise has no self-serve price → period_total_cents nil →
      # period_price_label renders bare "Custom" (no "/mo" or "/yr" suffix, which
      # would read as "Custom/mo"). Runner + member limits are :unlimited →
      # limit_label "Unlimited" and usage_pct nil, so the meters render the
      # gradient placeholder bar with no width/percentage.
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription_with(account, %{plan: "enterprise", status: "active"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Enterprise"
      # The plan strip shows bare "Custom", never a "$…" total nor a "/mo" suffix.
      assert html =~ "Custom"
      refute html =~ "Custom/mo"
      # Both meters read "/ Unlimited" (no numeric ceiling).
      assert html =~ "/ Unlimited"
      # usage_pct is nil for an :unlimited limit → NO progress bar at all (a bar
      # with no cap to fill against is meaningless); just the "N / Unlimited" count.
      refute html =~ "style=\"width:"
    end

    test "an annual subscriber's plan strip is priced per year, not per month", %{conn: conn} do
      # A team subscription mirrored as annual prices the strip at the annual
      # rate with a "/yr" suffix — one runner × $200/runner/yr (the strip total
      # carries cents via format_total) — never the monthly "/mo" suffix.
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id)

      insert_subscription_with(account, %{
        plan: "team",
        status: "active",
        billing_interval: "year"
      })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(lv, "#billing-current-plan", "$200.00/yr")
      refute has_element?(lv, "button[phx-click='set_cycle']")
      refute html =~ "/mo"
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

      # The "Manage billing" control is present once a customer exists…
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage billing")

      # …and clicking it redirects out to the (stub) portal URL.
      assert {:error, {:redirect, redirect}} = render_click(lv, "manage_billing", %{})
      url = redirect[:to] || redirect[:external]
      assert is_binary(url) and url =~ "stub-portal"
    end

    test "an invoice's PDF link fetches a signed URL and redirects to it", %{
      conn: conn,
      account: account
    } do
      account = attach_customer(account, "ctm_invoices_lv_01")
      insert_subscription(account, "active")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Recent invoices render once the async fetch resolves (stub
      # txn_stub_1..3), each with a PDF download.
      html = render_async(lv)
      assert html =~ "Recent invoices"
      assert has_element?(lv, "button[phx-click='download_invoice'][phx-value-id='txn_stub_1']")

      # Clicking it redirects out to the (stub) signed PDF URL.
      assert {:error, {:redirect, redirect}} =
               render_click(lv, "download_invoice", %{"id" => "txn_stub_1"})

      url = redirect[:to] || redirect[:external]
      assert is_binary(url) and url =~ "txn_stub_1"
    end

    test "a manage event on a no-customer account flashes :no_customer, no redirect", %{
      conn: conn,
      account: account
    } do
      # On an account with no paddle_customer_id, open_billing_portal short-circuits
      # to {:error, :no_customer} BEFORE any PaddleClient call, so the handler shows
      # the support flash and stays on the page (no redirect). The flash —
      # not a portal URL — is the proof the vendor was never reached.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # No customer attached → no Manage control rendered; push the event directly.
      refute has_element?(lv, "button[phx-click='manage_billing']")

      html = render_hook(lv, "manage_billing", %{})
      assert html =~ "No billing details are available yet"
    end

    test "an admin manages the subscription — the account's money is theirs to run", %{
      conn: conn,
      user: user,
      account: account
    } do
      downgrade_to(user, "admin")
      account = attach_customer(account, "ctm_admin_manage_01")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage billing")

      assert {:error, {:redirect, redirect}} = render_click(lv, "manage_billing", %{})
      url = redirect[:to] || redirect[:external]
      assert is_binary(url) and url =~ "stub-portal"
    end

    test "an operator pushing a crafted manage event is refused — flash, no redirect", %{
      conn: conn,
      user: user,
      account: account
    } do
      # manage_billing stops below the admin tier. An operator (who can VIEW
      # billing) crafting the manage_billing event is double-gated:
      # Permissions.gated denies it in the LV before the context is even called,
      # so the result is a permission flash and no portal redirect. (Customer
      # attached, to prove the gate — not the no-customer branch — is what
      # refuses.)
      downgrade_to(user, "operator")
      account = attach_customer(account, "ctm_operator_manage_01")

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
      # the button is suppressed (the manage-gated affordance never renders for them).
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

    test "reads the plan, its limits, and the catalogue, but buys nothing", %{
      conn: conn,
      user: user,
      account: account
    } do
      downgrade_to(user, "viewer")
      attach_customer(account, "ctm_viewer_no_ledger")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # What the tiers include is an operational fact on view_billing, alongside
      # the current plan and the usage meters…
      assert html =~ "Current plan"
      assert has_element?(lv, "#billing-usage", "Runners")
      assert has_element?(lv, "#billing-upgrade-offers")
      assert html =~ "Team"
      assert html =~ "See what your plan includes and how much you"
      # …while spending money is manage_billing's: the ledger and every card's
      # call to action are gone, so there is no control left to deny.
      refute html =~ "Recent invoices"
      refute html =~ "Upgrade to Team"
      refute has_element?(lv, "button[phx-click='upgrade']")
      refute has_element?(lv, "button[phx-click='manage_billing']")
      refute has_element?(lv, "button[phx-click='download_invoice']")
      assert has_element?(lv, "#billing-offer-team")
      assert has_element?(lv, "#billing-offer-enterprise")
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

  describe "as an admin" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      downgrade_to(user, "admin")
      %{conn: conn, user: user, account: account}
    end

    test "gets the whole billing surface — ledger, catalogue, and checkout", %{
      conn: conn,
      account: account
    } do
      account = attach_customer(account, "ctm_invoices_admin_01")
      insert_subscription(account, "active")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      html = render_async(lv)

      assert html =~ "Current plan"
      # An admin runs the account, so they run its money: the ledger, the
      # catalogue, and the checkout that acts on it.
      assert html =~ "Recent invoices"
      assert has_element?(lv, "button[phx-click='download_invoice'][phx-value-id='txn_stub_1']")
      assert has_element?(lv, "#billing-upgrade-offers")
      assert has_element?(lv, "#billing-offer-enterprise a", "Contact sales")
    end

    test "downloads an invoice PDF", %{conn: conn, account: account} do
      account = attach_customer(account, "ctm_invoices_admin_02")
      insert_subscription(account, "active")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      render_async(lv)

      assert {:error, {:redirect, redirect}} =
               render_click(lv, "download_invoice", %{"id" => "txn_stub_1"})

      url = redirect[:to] || redirect[:external]
      assert is_binary(url) and url =~ "txn_stub_1"
    end
  end

  describe "as an operator" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      downgrade_to(user, "operator")
      %{conn: conn, user: user, account: account}
    end

    test "reads the plan, its limits, and the catalogue, not the invoices", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Current plan"
      assert has_element?(lv, "#billing-usage", "Runners")
      assert has_element?(lv, "#billing-upgrade-offers")
      refute html =~ "Recent invoices"
      refute has_element?(lv, "button[phx-click='upgrade']")
    end

    test "a crafted invoice download is refused — the flash, not a PDF", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # No invoice row renders for an operator, so push the event directly: the
      # handler's Permissions.gated refuses before the read, and the Billing
      # context re-checks it too (IL-15) — either way it is a flash, not a PDF.
      html = render_hook(lv, "download_invoice", %{"id" => "txn_stub_1"})

      assert html =~ "permission to do that"
    end
  end

  describe "as a billing manager" do
    setup %{conn: conn} do
      # The finance seat sits BESIDE the owner (checkout needs an active owner
      # as the Paddle billing contact) — a second member holds the role.
      {_conn, _owner, account} = register_and_log_in(conn)
      manager = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: manager.id,
        role: "billing_manager"
      )

      %{conn: log_in_user(build_conn(), manager), account: account}
    end

    test "the money controls render and an upgrade starts checkout", %{
      conn: conn,
      account: account
    } do
      account = attach_customer(account, "ctm_billing_mgr_01")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The role holds manage_billing, so it gets the same money controls an
      # owner does — never the read-only locked copy.
      assert html =~ "Upgrade to Team"
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage billing")
      refute html =~ "Owner or billing manager only"

      # And the upgrade event passes both gates (LV + context) into checkout.
      assert {:error, {:redirect, %{to: url}}} =
               render_click(lv, "upgrade", %{"plan" => "team", "cycle" => "month"})

      assert url =~ "stub.paddle.test/checkout"
    end
  end

  describe "recent invoices (async)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "only three recent invoices render and the full ledger opens in billing", %{
      conn: conn,
      account: account
    } do
      attach_customer(account, "ctm_invoice_limit")
      insert_subscription(account, "active")
      {:ok, [invoice | _]} = Emisar.Billing.PaddleClient.Stub.list_transactions(%{})
      invoices = for n <- 1..5, do: Map.put(invoice, "id", "txn_recent_#{n}")
      Emisar.Config.put_override(:emisar, :paddle_client, InvoicePaddleClient)
      Emisar.Config.put_override(:emisar, :billing_test_invoice_owner, self())
      Emisar.Config.put_override(:emisar, :billing_test_invoice_result, {:ok, invoices})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      html = render_async(lv)

      assert_received {:invoice_request, %{customer: "ctm_invoice_limit", limit: 3}}

      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#billing-invoices button")
        |> LazyHTML.attribute("phx-value-id")

      assert ids == ["txn_recent_1", "txn_recent_2", "txn_recent_3"]

      assert {:error, {:redirect, %{to: url}}} =
               lv
               |> element("button[phx-click='manage_billing']", "View all invoices")
               |> render_click()

      assert url =~ "stub-portal"
    end

    test "the mount render is the loading state; the list arrives async", %{
      conn: conn,
      account: account
    } do
      account = attach_customer(account, "ctm_async_invoices_01")
      insert_subscription(account, "active")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The connected mount paints before Paddle answers — the section shows
      # its loading line and no invoice rows yet. (String asserts only: a
      # `has_element?` re-render can already have processed the async result.)
      assert html =~ "Loading invoices"
      refute html =~ "download_invoice"

      # The resolved fetch replaces the loading line with the list.
      html = render_async(lv)
      assert html =~ "Recent invoices"
      assert has_element?(lv, "button[phx-click='download_invoice'][phx-value-id='txn_stub_1']")
      refute html =~ "Loading invoices"
    end

    test "a never-billed account renders no invoice chrome at all", %{
      conn: conn,
      account: account
    } do
      # No Paddle customer → the fetch resolves to [] with no vendor call, so
      # neither the loading line (which would flash and vanish) nor the
      # section heading ever renders.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Loading invoices"

      html = render_async(lv)
      refute html =~ "Recent invoices"
    end

    test "Free workspaces hide invoices even with billing details", %{
      conn: conn,
      account: account
    } do
      attach_customer(account, "ctm_free_invoices")
      Emisar.Config.put_override(:emisar, :paddle_client, InvoicePaddleClient)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Loading invoices"
      refute html =~ "Recent invoices"
      html = render_async(lv)
      refute html =~ "Couldn't load recent invoices"
      refute html =~ "No invoices yet"
      refute has_element?(lv, "button[phx-click='retry_invoices']")
      assert has_element?(lv, "#billing-current-plan button", "Manage billing")

      section_ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(
          "#billing-current-plan, #billing-usage, #billing-features, #billing-upgrade-offers"
        )
        |> LazyHTML.attribute("id")

      assert section_ids == [
               "billing-current-plan",
               "billing-usage",
               "billing-features",
               "billing-upgrade-offers"
             ]
    end

    test "a paid workspace with no invoices shows an empty state and can refresh", %{
      conn: conn,
      account: account
    } do
      attach_customer(account, "ctm_empty_invoices")
      insert_subscription(account, "active")
      Emisar.Config.put_override(:emisar, :paddle_client, InvoicePaddleClient)
      Emisar.Config.put_override(:emisar, :billing_test_invoice_result, {:ok, []})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      html = render_async(lv)

      assert html =~ "Recent invoices"
      assert html =~ "No invoices yet."
      refute has_element?(lv, "#billing-invoices")
      assert has_element?(lv, "button[phx-click='manage_billing']", "View all invoices")

      Emisar.Config.put_override(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Stub)
      lv |> element("button[phx-click='retry_invoices']") |> render_click()
      html = render_async(lv)

      refute html =~ "No invoices yet."
      assert has_element?(lv, "#billing-invoices button[phx-value-id='txn_stub_1']")
    end

    test "a Paddle failure shows the inline retry state, and retry recovers", %{
      conn: conn,
      account: account
    } do
      account = attach_customer(account, "ctm_invoices_down_01")
      insert_subscription(account, "active")
      Emisar.Config.put_override(:emisar, :paddle_client, InvoicePaddleClient)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The failed fetch renders the section-level failure state — with a
      # retry — while the rest of the page stays up.
      html = render_async(lv)
      assert html =~ "load recent invoices"
      refute html =~ "not a problem with your payment"
      assert has_element?(lv, "button[phx-click='retry_invoices']", "Try again")
      assert html =~ "Current plan"

      # Paddle comes back; Try again re-runs the fetch in place.
      Emisar.Config.put_override(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Stub)
      render_click(lv, "retry_invoices", %{})

      html = render_async(lv)
      assert html =~ "Recent invoices"
      assert has_element?(lv, "button[phx-click='retry_invoices']", "Refresh invoices")
    end
  end

  describe "subscription health banner" do
    test "a past_due subscription shows the rose payment banner + a manage action", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      attach_customer(account, "ctm_past_due")
      insert_subscription(account, "past_due")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Payment overdue"
      assert html =~ "Update your payment details"
      # The owner can fix it — the banner surfaces the billing portal.
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage billing")
    end

    test "a canceled subscription shows the amber banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "canceled")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Subscription ended"
      assert html =~ "is on the Free plan"
      assert html =~ "restore paid features"
    end

    test "a healthy account shows no failure banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Payment overdue"
      refute html =~ "Subscription ended"
    end

    test "a scheduled cancellation keeps paid access and names its deadline", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      effective_at = DateTime.add(DateTime.utc_now(), 86_400, :second)

      insert_subscription_with(account, %{
        plan: "team",
        status: "active",
        scheduled_change_action: "cancel",
        scheduled_change_effective_at: effective_at,
        current_period_end: effective_at
      })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Subscription ending"
      assert html =~ "Your paid features remain available until"
      assert has_element?(lv, "#subscription-access-changes-at")
      refute has_element?(lv, "#billing-access-ends-on")
      refute html =~ "Next charge"
      assert html =~ "Team"
    end

    test "a paused subscription shows the amber paused banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "paused")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Subscription paused"
      assert html =~ "is on the Free plan"
      refute has_element?(lv, "#billing-upgrade-offers")
      refute has_element?(lv, "button[phx-click='set_cycle']")
      # Amber FYI, not the rose payment-failure tone.
      refute html =~ "Payment overdue"
    end

    test "an unknown status fails closed with a recovery-oriented banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "some_unmodeled_status")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Billing status unavailable"
      assert html =~ "Paid features are temporarily unavailable"
      refute html =~ "cleanup remain available"
      assert html =~ "Current plan"
    end

    test "the banner distinguishes dunning access from expired access", %{conn: _conn} do
      cases = [
        {"past_due", "paid features remain available"},
        {"paused", "restore paid features"},
        {"canceled", "restore paid features"}
      ]

      for {status, advisory_body} <- cases do
        {conn, _user, account} = register_and_log_in(build_conn())
        insert_subscription(account, status)

        {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

        assert html =~ advisory_body
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

      assert html =~ "Payment overdue"
      refute has_element?(lv, "button[phx-click='manage_billing']")
    end
  end

  describe "billing refresh" do
    test "confirmed billing facts update an already-open Free page", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      render_async(lv)

      assert has_element?(lv, "button[phx-click='upgrade']", "Upgrade to Team")
      refute has_element?(lv, "button[phx-click='manage_billing']")
      assert has_element?(lv, "li span.text-zinc-400", "Single sign-on (OIDC)")

      attach_customer(account, "ctm_confirmed_after_mount")

      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_confirmed_after_mount",
        unit_price_amount: 2000,
        quantity: 2,
        currency_code: "EUR",
        entitlements: %{"runners_limit" => 250, "features_scim_enabled?" => true}
      )

      Fixtures.Runners.create_runner(account_id: account.id)
      member = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      html = refresh_billing(lv)
      assert html =~ "€40.00/mo"
      assert html =~ "/ 250"
      assert billing_summary(lv).runner_count == 1
      assert billing_summary(lv).member_count == 2
      assert has_element?(lv, "li span.text-zinc-300", "Single sign-on (OIDC)")
      assert has_element?(lv, "li span.text-zinc-300", "SCIM directory sync")
      refute has_element?(lv, "#billing-offer-team")
      assert has_element?(lv, "#billing-offer-enterprise")
      refute has_element?(lv, "#billing-offer-enterprise", "SCIM directory sync")
      refute has_element?(lv, "button[phx-click='set_cycle']")
      refute has_element?(lv, "button[phx-click='upgrade']")
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage billing")

      # No provider call on the tick. The newly available ledger can be loaded
      # explicitly using the current customer, despite the stale mount account.
      refute has_element?(lv, "button[phx-click='download_invoice']")
      assert has_element?(lv, "button[phx-click='retry_invoices']", "Refresh invoices")
      render_click(lv, "retry_invoices", %{})
      render_async(lv)
      assert has_element?(lv, "button[phx-click='download_invoice'][phx-value-id='txn_stub_1']")

      assert {:error, {:redirect, %{to: url}}} = render_click(lv, "manage_billing", %{})
      assert url =~ "stub-portal"
    end

    test "complimentary changes refresh access without claiming recurring charges", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert {:ok, _} = Emisar.Billing.grant_complimentary_plan(account, "team")
      html = refresh_billing(lv)
      assert html =~ "Complimentary"
      assert html =~ "/ 100"
      refute html =~ "$20.00/mo"
      refute has_element?(lv, "button[phx-click='manage_billing']")
      refute has_element?(lv, "button[phx-click='upgrade']")

      assert has_element?(
               lv,
               "#billing-current-plan a[href^='mailto:support@emisar.dev']",
               "Contact support"
             )

      refute has_element?(lv, "#billing-upgrade-offers")
      refute has_element?(lv, "button[phx-click='set_cycle']")

      assert {:ok, _} = Emisar.Billing.revoke_complimentary_plan(account)
      html = refresh_billing(lv)
      refute html =~ "Complimentary"
      refute html =~ "$0/mo"
      assert html =~ "/ 3"
      assert has_element?(lv, "button[phx-click='upgrade']", "Upgrade to Team")
      assert has_element?(lv, "li span.text-zinc-400", "Single sign-on (OIDC)")
    end

    for {action, title} <- [{"pause", "Subscription paused"}, {"cancel", "Subscription ended"}] do
      test "an elapsed scheduled #{action} refreshes access before a terminal webhook", %{
        conn: conn
      } do
        {conn, _user, account} = register_and_log_in(conn)
        attach_customer(account, "ctm_scheduled_#{unquote(action)}")
        deadline = DateTime.add(DateTime.utc_now(), 86_400, :second)

        subscription =
          insert_subscription_with(account, %{
            plan: "team",
            status: "active",
            paddle_subscription_id: "sub_scheduled_#{unquote(action)}",
            scheduled_change_action: unquote(action),
            scheduled_change_effective_at: deadline
          })

        {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
        assert billing_summary(lv).plan == "team"

        subscription
        |> Ecto.Changeset.change(
          scheduled_change_effective_at: DateTime.add(DateTime.utc_now(), -1, :second)
        )
        |> Emisar.Repo.update!()

        html = refresh_billing(lv)
        assert html =~ unquote(title)
        assert html =~ "is on the Free plan"
        assert billing_summary(lv).plan == "free"
        assert billing_summary(lv).subscription_status == "active"
        # An unconfirmed terminal state is still an existing subscription.
        refute has_element?(lv, "button[phx-click='upgrade']")
        assert has_element?(lv, "#billing-current-plan button[phx-click='manage_billing']")
        refute has_element?(lv, "#billing-upgrade-offers")
      end
    end

    test "a nearer deadline shortens the timer and stale ticks cannot fork it", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      {old_attempt, old_timer} = :sys.get_state(lv.pid).socket.assigns.billing_refresh

      insert_subscription_with(account, %{
        plan: "team",
        status: "active",
        scheduled_change_action: "pause",
        scheduled_change_effective_at: DateTime.add(DateTime.utc_now(), 10, :second)
      })

      refresh_billing(lv)
      current = {_attempt, timer} = :sys.get_state(lv.pid).socket.assigns.billing_refresh
      refute Process.read_timer(old_timer)
      assert Process.read_timer(timer) <= 10_000

      send(lv.pid, {:refresh_billing, old_attempt})
      render(lv)
      assert :sys.get_state(lv.pid).socket.assigns.billing_refresh == current
    end

    test "periodic refresh leaves invoice failures for explicit retry", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      attach_customer(account, "ctm_refresh_invoice_failure")
      insert_subscription(account, "active")
      Emisar.Config.put_override(:emisar, :paddle_client, InvoicePaddleClient)
      Emisar.Config.put_override(:emisar, :billing_test_invoice_owner, self())
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      render_async(lv)
      assert_received {:invoice_request, _}

      for _ <- 1..3, do: refresh_billing(lv)
      render_async(lv)
      refute_received {:invoice_request, _}
      assert has_element?(lv, "button[phx-click='retry_invoices']", "Try again")

      render_click(lv, "retry_invoices", %{})
      render_async(lv)
      assert_received {:invoice_request, _}
    end

    for status <- ["paused", "some_unmodeled_status"] do
      test "#{status} subscriptions do not offer another checkout", %{conn: conn} do
        {conn, _user, account} = register_and_log_in(conn)

        insert_subscription_with(account, %{
          plan: "team",
          status: unquote(status),
          paddle_subscription_id: "sub_existing_#{unquote(status)}"
        })

        {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
        assert billing_summary(lv).plan == "free"
        refute has_element?(lv, "#billing-upgrade-offers")
        refute has_element?(lv, "button[phx-click='upgrade']")
        refute has_element?(lv, "button[phx-click='manage_billing']")

        assert has_element?(
                 lv,
                 "#billing-current-plan a[href^='mailto:support@emisar.dev']",
                 "Contact support"
               )

        attach_customer(account, "ctm_existing_#{unquote(status)}")
        refresh_billing(lv)
        refute has_element?(lv, "button[phx-click='upgrade']")
        assert has_element?(lv, "#billing-current-plan button[phx-click='manage_billing']")
      end
    end

    test "a canceled custom plan permits a new Team checkout", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      insert_subscription_with(account, %{
        plan: "enterprise",
        status: "canceled",
        paddle_subscription_id: "sub_canceled_custom"
      })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      assert billing_summary(lv).plan == "free"
      assert has_element?(lv, "button[phx-click='upgrade']", "Upgrade to Team")
      assert has_element?(lv, "#billing-offer-enterprise a", "Contact sales")
    end
  end

  defp billing_summary(lv), do: :sys.get_state(lv.pid).socket.assigns.summary

  defp refresh_billing(lv) do
    {attempt, _timer} = :sys.get_state(lv.pid).socket.assigns.billing_refresh
    send(lv.pid, {:refresh_billing, attempt})
    render(lv)
  end

  defp insert_subscription(account, status) do
    {:ok, subscription} =
      %{
        account_id: account.id,
        plan: "team",
        status: status,
        collection_mode: if(status == "past_due", do: "automatic")
      }
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
