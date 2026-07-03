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
      conn = log_in_user(conn, Fixtures.Users.create_user())

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

    test "a fresh account's three pillars render as the onboarding CTAs",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # The onboarding checklist IS the pillars' zero states — a fresh account
      # (no runners, no agent keys, a team of one) reads its three next steps
      # off the same three cards that later carry live fleet state.
      assert html =~ "Install your first runner"
      assert html =~ "Connect an LLM agent"
      assert html =~ "Invite your team"

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
      # The runners pillar graduates from the install CTA to live state
      # (one registered runner, not connected in a test).
      assert html =~ "/ 1 online"
      refute html =~ "Install your first runner"
      assert html =~ "Recent runs"
      # The agents pillar still shows its CTA — no API key was minted in
      # this test.
      assert html =~ "Connect an LLM agent"
      # A runner with nothing dispatched yet: the runs panel's zero state
      # deep-links the first runner's catalog as the dispatch nudge.
      assert html =~ "dispatch an action from its catalog"
    end

    test "the dispatch nudge appears with a runner-but-no-runs and clears after the first run",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "dispatch an action from its catalog"
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
      refute html2 =~ "dispatch an action from its catalog"
    end

    # every sub-read on the dashboard flows through
    # `current_subject`, so the board is account-scoped: A's operator sees A's
    # recent run + pending approval and never B's, even though both accounts have
    # both. (The foreign-slug 404 lives in account_slug_authz_test; this is the
    # in-account data scoping of the dashboard's own reads.)
    test "cross-account — the dashboard shows only this account's data", %{conn: conn} do
      {conn, user_a, account_a} = register_and_log_in(conn)
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id)

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
      {user_b, account_b, _subject_b} = Fixtures.Subjects.owner_subject()
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)

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
      # (segment match: run_row renders the id through dotted_mono, which puts
      # a <wbr> after each dot, so the full dotted string never appears verbatim)
      assert html =~ "alpha_dash"
      # …and nothing from B leaks onto A's board.
      refute html =~ "bravo_dash"
    end

    # the dashboard is a read-only triage screen: its
    # pillar cards are plain `<.link navigate>`s to real routes, not
    # server-driven actions. A fresh account renders the three onboarding CTAs
    # linking to install + agents + team invite; the LV defines no mutating
    # `handle_event`, so there's nothing to abuse.
    test "pillar cards are plain navigation links to real routes (read-only)",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      # The zero-state pillar CTAs link straight to the install wizard, the
      # agents page, and the team invite — real routes, reached by navigation,
      # not a phx-click handler.
      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/runners/install"}']",
               "Install your first runner"
             )

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/agents"}']",
               "Connect an LLM agent"
             )

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/team/invite"}']",
               "Invite your team"
             )

      # The runs panel's "View all" is a plain link to the runs list.
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/runs"}']")
    end

    test "account broadcasts schedule a debounced stats reload", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "Install your first runner"

      # A runner registers elsewhere; the dashboard hears the account
      # broadcast (2-tuple) or a presence_diff and ARMS a debounced reload
      # rather than re-querying per message. The reload fires on the
      # :reload_dashboard timer — inject it directly to stand in for the timer.
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      send(lv.pid, {:runner_updated, runner})
      send(lv.pid, :reload_dashboard)
      refute render(lv) =~ "Install your first runner"

      send(lv.pid, %{event: "presence_diff"})
      send(lv.pid, :reload_dashboard)
      assert render(lv) =~ "/ 1 online"

      # Unrelated message shapes are ignored, never a crash.
      send(lv.pid, :stray_message)
      assert render(lv) =~ "/ 1 online"
    end
  end

  describe "billing-status banner" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "a past_due subscription surfaces the alert + a manage-billing link for an owner",
         %{conn: conn, account: account} do
      Fixtures.Accounts.create_subscription(account, "team", status: "past_due")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "Payment past due"
      # The owner can act — the banner links to the billing page (manage there).
      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/billing"}']",
               "Manage billing"
             )
    end

    test "a healthy account shows no billing banner", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      refute html =~ "Payment past due"
      refute html =~ "Subscription canceled"
    end

    test "a viewer sees the alert but not the manage action (it's owner-gated)", %{
      conn: conn,
      user: user,
      account: account
    } do
      Fixtures.Accounts.create_subscription(account, "team", status: "past_due")
      {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Fixtures.Memberships.force_role(membership, "viewer")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      # Every member should KNOW there's a payment problem…
      assert html =~ "Payment past due"
      # …but only an owner gets the manage affordance.
      refute has_element?(lv, "a[href='/app/settings/billing']", "Manage billing")
    end
  end

  describe "plan / packs headroom banners" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    # at the plan's runner cap the dashboard renders the
    # rose at-limit banner (the next register would 402). The free plan caps at
    # 3 runners; fill all three.
    test "at the runner limit, the at-limit banner renders", %{conn: conn, account: account} do
      for _ <- 1..3, do: Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "You&#39;re at your runner limit (3 of 3)."
    end

    # (the near-limit half) — one slot short of the cap shows
    # the softer amber "one slot left" variant, not the at-limit rose one.
    test "near the runner limit, the amber 'one slot left' banner renders", %{
      conn: conn,
      account: account
    } do
      for _ <- 1..2, do: Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "One runner slot left"
      refute html =~ "at your runner limit"
    end

    # when a runner advertises a pack version no operator
    # has trusted yet (`count_pending_pack_versions > 0`), the dashboard surfaces
    # the amber packs-pending-trust banner linking to the Packs page (dispatch is
    # blocked against those packs until an admin trusts the new hash).
    test "a pending pack version surfaces the packs-pending-trust banner", %{
      conn: conn,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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

  describe "a billing_manager's console" do
    test "the dashboard renders and the nav offers only what the role can open", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)

      member = Emisar.Fixtures.Users.create_user() |> Emisar.Fixtures.Users.confirm_user()

      Emisar.Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "billing_manager"
      )

      conn = log_in_user(Phoenix.ConnTest.build_conn(), member)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      # Billing + Team stay reachable (billing is the seat's job; the roster
      # view is every member's floor).
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/settings/billing"}']")
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/settings/team"}']")

      # The sections the role holds no view permission for are gone.
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/runbooks"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/policies"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/runs"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/audit"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/runners"}']")
    end
  end
end
