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

  defp downgrade_to_viewer(user) do
    {:ok, m} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Emisar.Fixtures.force_membership_role(m, "viewer")
  end

  describe "as an owner" do
    test "renders the current plan and usage meters", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # Free plan strip + the two usage meters.
      assert html =~ "Current plan"
      assert html =~ "Free"
      assert html =~ "Runners"
      assert html =~ "Team members"
      # Owner sees the upgrade CTA (viewers don't — asserted below).
      assert html =~ "Upgrade to Team"
    end

    test "the upgrade event starts checkout and redirects externally", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The owner is offered the upgrade control (the strip CTA + the
      # team plan card both carry it).
      assert has_element?(lv, "button[phx-click='upgrade'][phx-value-plan='team']")

      # `Billing.start_checkout/3` returns a checkout URL (the stub
      # `/paddle-checkout-stub?plan=…` when no Paddle price id is
      # configured, or a stub Paddle URL when one is) and the LV
      # redirects to it. Drive the event by name to avoid matching the
      # two identical "team" buttons; assert the external redirect, not
      # the exact host, so the test is immune to whether
      # `:paddle_price_ids` happens to be set by a concurrent test.
      # Accept either redirect shape: an internal `%{to:}` to the stub path
      # (no :paddle_price_ids configured — the test default) or an external
      # `%{external:}` to a Paddle URL (if a concurrent test set the price id).
      assert {:error, {:redirect, redirect}} =
               render_click(lv, "upgrade", %{"plan" => "team"})

      url = redirect[:to] || redirect[:external]
      assert is_binary(url) and url != ""
    end

    test "the enterprise card surfaces contact-sales, not checkout", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/billing")

      html =
        lv
        |> element("button", "Contact sales")
        |> render_click()

      assert html =~ "We&#39;ll be in touch" or html =~ "We'll be in touch"
      # Still on the page — no external redirect for the sales-led tier.
      assert html =~ "Current plan"
    end
  end

  describe "as a viewer" do
    test "no upgrade controls render", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      downgrade_to_viewer(user)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/billing")

      # The plan/usage is visible to everyone who can view billing…
      assert html =~ "Current plan"
      # …but the owner-only upgrade CTA + per-card upgrade buttons are
      # replaced with the read-only affordance.
      refute html =~ "Upgrade to Team"
      assert html =~ "Owners only"
    end

    test "a crafted upgrade event is refused — flash, no redirect", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      downgrade_to_viewer(user)

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
  end

  defp insert_subscription(account, status) do
    {:ok, subscription} =
      %{account_id: account.id, plan: "team", status: status}
      |> Emisar.Billing.Subscription.Changeset.upsert()
      |> Emisar.Repo.insert()

    subscription
  end
end
