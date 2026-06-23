defmodule EmisarWeb.DashboardLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app")
    end

    test "logs out and redirects a fully-suspended user", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn)

      # Suspend the user's only membership: the session can no longer resolve
      # an account, and all-suspended means access is revoked (not onboarding),
      # so the auth pipeline signs them out with a flash.
      {1, _} =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_user_id(user.id)
        |> Emisar.Repo.update_all(set: [disabled_at: DateTime.utc_now()])

      assert {:error, {:redirect, %{to: "/sign_in", flash: %{"error" => message}}}} =
               live(conn, ~p"/app")

      assert message =~ "suspended"
    end

    test "redirects a logged-in user with no account to onboarding", %{conn: conn} do
      # A bare user (no membership at all) isn't locked out — they're sent to
      # onboarding to create their first account.
      conn = log_in_user(conn, Emisar.Fixtures.user_fixture())

      assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, ~p"/app")
    end

    test "unconfirmed users see the verify-email banner and can resend", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      # register_and_log_in confirms by default — simulate the unverified state.
      {:ok, _} = user |> Ecto.Changeset.change(confirmed_at: nil) |> Emisar.Repo.update()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "Verify your email"
      assert html =~ "Resend email"

      # The button is wired to the global :email_confirmation on_mount hook,
      # not to DashboardLive — clicking it still re-sends from any page.
      html = lv |> element("button", "Resend email") |> render_click()
      assert html =~ "Confirmation email sent"
    end

    test "confirmed users see no verify-email banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")
      refute html =~ "Verify your email"
    end

    test "fresh accounts see the onboarding wizard with both checklist cards",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # Two onboarding cards — runner + LLM — sit at the top of the
      # dashboard as a wizard checklist. The runner card links to
      # /app/runners/install where the actual install command lives.
      assert html =~ "Connect a runner"
      assert html =~ "Connect an LLM"

      # No auto-minted install key — the dashboard doesn't mint
      # anymore. The runners/install page mints when the operator
      # navigates into it.
      assert Emisar.Repo.all(Emisar.Runners.AuthKey) == []
    end

    test "renders the populated dashboard once a runner exists", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _agent} =
        Emisar.Runners.create_runner(
          %{
            "name" => "runner-1",
            "group" => "default"
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "Runners online"
      assert html =~ "Recent runs"
      # The runner-onboarding card disappears once a runner exists.
      refute html =~ "Connect a runner"
      # LLM onboarding card still shows — no API key was minted in
      # this test.
      assert html =~ "Connect an LLM"
      # A runner with nothing dispatched yet gets the dispatch nudge.
      assert html =~ "Dispatch your first action"
    end

    test "the dispatch nudge appears with a runner-but-no-runs and clears after the first run",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "Dispatch your first action"
      # Deep-linked to the runner's own catalog, not the runners list.
      assert html =~ ~p"/app/#{account}/runners/#{runner.id}"

      {:ok, _run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          args: %{},
          reason: "first run",
          source: "operator"
        })

      {:ok, _lv2, html2} = live(conn, ~p"/app/#{account}")
      refute html2 =~ "Dispatch your first action"
    end

    # every sub-read on the dashboard flows through
    # `current_subject`, so the board is account-scoped: A's operator sees A's
    # recent run + pending approval and never B's, even though both accounts have
    # both. (The foreign-slug 404 lives in account_slug_authz_test; this is the
    # in-account data scoping of the dashboard's own reads.)
    test "cross-account — the dashboard shows only this account's data", %{conn: conn} do
      {conn, user_a, account_a} = register_and_log_in(conn)
      runner_a = Emisar.Fixtures.runner_fixture(account_id: account_a.id)

      {:ok, run_a} =
        Emisar.Runs.create_run(%{
          account_id: account_a.id,
          runner_id: runner_a.id,
          action_id: "linux.alpha_dash",
          args: %{},
          reason: "a's run",
          source: "operator"
        })

      {:ok, _request_a} = Emisar.Approvals.create_request(run_a, user_a.id, "needs sign-off")

      # Account B (a different owner) has its own runner, run, and approval.
      {user_b, account_b, _subject_b} = Emisar.Fixtures.owner_subject_fixture()
      runner_b = Emisar.Fixtures.runner_fixture(account_id: account_b.id)

      {:ok, run_b} =
        Emisar.Runs.create_run(%{
          account_id: account_b.id,
          runner_id: runner_b.id,
          action_id: "linux.bravo_dash",
          args: %{},
          reason: "b's run",
          source: "operator"
        })

      {:ok, _request_b} = Emisar.Approvals.create_request(run_b, user_b.id, "b's sign-off")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account_a}")

      # A's run (recent-runs row) + A's pending approval (the lead panel) show…
      assert html =~ "linux.alpha_dash"
      # …and nothing from B leaks onto A's board.
      refute html =~ "linux.bravo_dash"
    end

    # the dashboard is a read-only triage screen: its
    # quick-action cards (onboarding checklist + the three stat tiles) are plain
    # `<.link navigate>`s to real routes, not server-driven actions. A fresh
    # account renders the two onboarding cards linking to install + agents; the
    # LV defines no mutating `handle_event`, so there's nothing to abuse.
    test "quick-action cards are plain navigation links to real routes (read-only)",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      # The onboarding cards link straight to the install wizard and the agents
      # page — real routes, reached by navigation, not a phx-click handler.
      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/runners/install"}']",
               "Connect a runner"
             )

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/agents"}']",
               "Connect an LLM"
             )

      # The three stat tiles are themselves links to their list pages (not
      # buttons): runners, runs, team.
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/runners"}']")
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/runs"}']")
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/settings/team"}']")
    end

    test "account broadcasts schedule a debounced stats reload", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "Connect a runner"

      # A runner registers elsewhere; the dashboard hears the account
      # broadcast (2-tuple) or a presence_diff and ARMS a debounced reload
      # rather than re-querying per message. The reload fires on the
      # :reload_dashboard timer — inject it directly to stand in for the timer.
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      send(lv.pid, {:runner_updated, runner})
      send(lv.pid, :reload_dashboard)
      refute render(lv) =~ "Connect a runner"

      send(lv.pid, %{event: "presence_diff"})
      send(lv.pid, :reload_dashboard)
      assert render(lv) =~ "Runners online"

      # Unrelated message shapes are ignored, never a crash.
      send(lv.pid, :stray_message)
      assert render(lv) =~ "Runners online"
    end
  end

  describe "billing-status banner" do
    test "a past_due subscription surfaces the alert + a manage-billing link for an owner",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Emisar.Fixtures.subscription_fixture(account, "team", status: "past_due")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "Payment past due"
      # The owner can act — the banner links to the billing page (manage there).
      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/billing"}']",
               "Manage billing"
             )
    end

    test "a healthy account shows no billing banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      refute html =~ "Payment past due"
      refute html =~ "Subscription canceled"
    end

    test "a viewer sees the alert but not the manage action (it's owner-gated)", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Emisar.Fixtures.subscription_fixture(account, "team", status: "past_due")
      {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Emisar.Fixtures.force_membership_role(membership, "viewer")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      # Every member should KNOW there's a payment problem…
      assert html =~ "Payment past due"
      # …but only an owner gets the manage affordance.
      refute has_element?(lv, "a[href='/app/settings/billing']", "Manage billing")
    end
  end

  describe "plan / packs headroom banners" do
    # at the plan's runner cap the dashboard renders the
    # rose at-limit banner (the next register would 402). The free plan caps at
    # 3 runners; fill all three.
    test "at the runner limit, the at-limit banner renders", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      for _ <- 1..3, do: Emisar.Fixtures.runner_fixture(account_id: account.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "You&#39;re at your runner limit (3 of 3)."
    end

    # (the near-limit half) — one slot short of the cap shows
    # the softer amber "one slot left" variant, not the at-limit rose one.
    test "near the runner limit, the amber 'one slot left' banner renders", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      for _ <- 1..2, do: Emisar.Fixtures.runner_fixture(account_id: account.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "One runner slot left"
      refute html =~ "at your runner limit"
    end

    # when a runner advertises a pack version no operator
    # has trusted yet (`count_pending_pack_versions > 0`), the dashboard surfaces
    # the amber packs-pending-trust banner linking to the Packs page (dispatch is
    # blocked against those packs until an admin trusts the new hash).
    test "a pending pack version surfaces the packs-pending-trust banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)

      # A custom (no-baseline) pack advertises an action and lands :pending — the
      # runner reports a hash no operator has trusted.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:PENDING"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "low",
              "args" => []
            }
          ]
        })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "trust review"
      # …and it links to the Packs page where the admin trusts/rejects the hash.
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/packs"}']")
    end
  end
end
