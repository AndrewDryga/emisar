defmodule EmisarWeb.BillingLiveTest.InvoicesDownPaddleClient do
  @moduledoc false
  # The stub Paddle with ONLY the transaction list failing — exercises the
  # invoice section's failed state without breaking the checkout/portal/catalog
  # calls the rest of the page depends on.
  @behaviour Emisar.Billing.PaddleClient

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
  def list_transactions(_attrs), do: {:error, :paddle_unavailable}
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
  alias EmisarWeb.BillingLiveTest.InvoicesDownPaddleClient

  defp downgrade_to(user, role) when is_binary(role) do
    {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Fixtures.Memberships.force_role(membership, role)
  end

  describe "as an owner" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, account: account, user: user}
    end

    test "renders the current plan, usage meters, and contextual support nav", %{
      conn: conn,
      account: account,
      user: user
    } do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Free plan strip + the two usage meters.
      assert html =~ "Current plan"
      assert html =~ "Free"
      assert html =~ "Runners"
      assert html =~ "Team members"
      # Owner sees the upgrade CTA (viewers don't — asserted below).
      assert html =~ "Upgrade to Team"
      # The Enterprise plan card carries the same benefit the pricing page promises.
      assert html =~ "Dedicated Slack support channel"
      assert html =~ "subject=Support%20request%20-%20Test%20Co"
      assert html =~ "Account%20ID%3A%20#{account.id}"
      assert html =~ "User%3A%20#{String.replace(user.email, "@", "%40")}"
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
      assert html =~ "most popular"
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

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The special-state notice names the custom plan and carries the one real
      # action — email support (a prefilled mailto), not a self-serve control.
      assert html =~ "Custom Enterprise plan"
      assert html =~ "mailto:support@emisar.dev"
      assert html =~ "subject=Billing%20question%20-%20Test%20Co"
      assert html =~ "Account%20ID%3A%20#{account.id}"
      assert html =~ "User%3A%20#{String.replace(user.email, "@", "%40")}"

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
      assert html =~ "Custom Enterprise plan"
      assert html =~ "Contact support to switch"
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

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "$200.00/yr"
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

      # The "Manage subscription" control is present once a customer exists…
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage subscription")

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
      # the "upgrade first" flash and stays on the page (no redirect). The flash —
      # not a portal URL — is the proof the vendor was never reached.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # No customer attached → no Manage control rendered; push the event directly.
      refute has_element?(lv, "button[phx-click='manage_billing']")

      html = render_hook(lv, "manage_billing", %{})
      assert html =~ "upgrade to a paid plan first"
    end

    test "an admin manages the subscription — the account's money is theirs to run", %{
      conn: conn,
      user: user,
      account: account
    } do
      downgrade_to(user, "admin")
      account = attach_customer(account, "ctm_admin_manage_01")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage subscription")

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

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # What the tiers include is an operational fact on view_billing, alongside
      # the current plan and the usage meters…
      assert html =~ "Current plan"
      assert html =~ "Usage"
      assert html =~ "Plans"
      assert html =~ "Team"
      # …while spending money is manage_billing's: the ledger and every card's
      # call to action are gone, so there is no control left to deny.
      refute html =~ "Recent invoices"
      refute html =~ "Upgrade to Team"
      refute has_element?(lv, "button[phx-click='upgrade']")
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

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")
      html = render_async(lv)

      assert html =~ "Current plan"
      # An admin runs the account, so they run its money: the ledger, the
      # catalogue, and the checkout that acts on it.
      assert html =~ "Recent invoices"
      assert has_element?(lv, "button[phx-click='download_invoice'][phx-value-id='txn_stub_1']")
      assert html =~ "Plans"
      assert has_element?(lv, "button[phx-click='upgrade']")
    end

    test "downloads an invoice PDF", %{conn: conn, account: account} do
      account = attach_customer(account, "ctm_invoices_admin_02")

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
      assert html =~ "Usage"
      assert html =~ "Plans"
      refute html =~ "Recent invoices"
      refute has_element?(lv, "button[phx-click='upgrade']")
    end

    test "a crafted invoice download is refused — the flash, not a PDF", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # No invoice row renders for an operator, so push the event directly:
      # the Billing context gates the read, not the template (IL-15).
      html = render_hook(lv, "download_invoice", %{"id" => "txn_stub_1"})

      assert html =~ "Couldn&#39;t open that invoice"
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
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage subscription")
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

    test "the mount render is the loading state; the list arrives async", %{
      conn: conn,
      account: account
    } do
      account = attach_customer(account, "ctm_async_invoices_01")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The connected mount paints before Paddle answers — the section shows
      # its loading line and no invoice rows yet. (String asserts only: a
      # `has_element?` re-render can already have processed the async result.)
      assert html =~ "Loading payment history"
      refute html =~ "download_invoice"

      # The resolved fetch replaces the loading line with the list.
      html = render_async(lv)
      assert html =~ "Recent invoices"
      assert has_element?(lv, "button[phx-click='download_invoice'][phx-value-id='txn_stub_1']")
      refute html =~ "Loading payment history"
    end

    test "a never-billed account renders no invoice chrome at all", %{
      conn: conn,
      account: account
    } do
      # No Paddle customer → the fetch resolves to [] with no vendor call, so
      # neither the loading line (which would flash and vanish) nor the
      # section heading ever renders.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Loading payment history"

      html = render_async(lv)
      refute html =~ "Recent invoices"
    end

    test "a Paddle failure shows the inline retry state, and retry recovers", %{
      conn: conn,
      account: account
    } do
      account = attach_customer(account, "ctm_invoices_down_01")
      Emisar.Config.put_override(:emisar, :paddle_client, InvoicesDownPaddleClient)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The failed fetch renders the section-level failure state — with a
      # retry — while the rest of the page stays up.
      html = render_async(lv)
      assert html =~ "load recent invoices"
      assert html =~ "not a problem with your payment"
      assert has_element?(lv, "button[phx-click='retry_invoices']", "Try again")
      assert html =~ "Current plan"

      # Paddle comes back; Try again re-runs the fetch in place.
      Emisar.Config.put_override(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Stub)
      render_click(lv, "retry_invoices", %{})

      html = render_async(lv)
      assert html =~ "Recent invoices"
      refute has_element?(lv, "button[phx-click='retry_invoices']")
    end
  end

  describe "subscription health banner" do
    test "a past_due subscription shows the rose payment banner + a manage action", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "past_due")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Payment recovery in progress"
      assert html =~ "Update your payment details"
      # The owner can fix it — the banner surfaces the billing portal.
      assert has_element?(lv, "button[phx-click='manage_billing']", "Manage billing")
    end

    test "a canceled subscription shows the amber banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "canceled")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Subscription ended"
      assert html =~ "Free limits"
      assert html =~ "Paid integrations are dormant"
    end

    test "a healthy account shows no failure banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      refute html =~ "Payment recovery in progress"
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

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Paid access is scheduled to end"
      assert html =~ "Paid features remain available until the scheduled end"
      assert html =~ "Ends on"
      refute html =~ "Next charge"
      assert html =~ "Team"
    end

    test "a paused subscription shows the amber paused banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "paused")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Paid access paused"
      assert html =~ "Free limits"
      # Amber FYI, not the rose payment-failure tone.
      refute html =~ "Payment recovery in progress"
    end

    test "an unknown status fails closed with a recovery-oriented banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      insert_subscription(account, "some_unmodeled_status")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      assert html =~ "Billing status unavailable"
      assert html =~ "Paid features are temporarily unavailable"
      assert html =~ "Billing, recovery, and cleanup remain available"
      assert html =~ "Current plan"
    end

    test "the banner distinguishes dunning access from expired access", %{conn: _conn} do
      cases = [
        {"past_due", "Paid features remain available"},
        {"paused", "Paid integrations are dormant"},
        {"canceled", "Paid integrations are dormant"}
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

      assert html =~ "Payment recovery in progress"
      refute has_element?(lv, "button[phx-click='manage_billing']")
    end
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
