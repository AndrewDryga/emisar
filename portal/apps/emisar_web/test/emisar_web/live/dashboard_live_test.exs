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

    test "an operator lands on the dashboard, not billing", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      # An operator can read runs, so the dashboard is theirs — the first-run
      # checklist (a fresh account has no runs), not a bounce to billing.
      {:ok, _lv, html} =
        build_conn()
        |> log_in_user(operator)
        |> live(~p"/app/#{account}")

      assert html =~ "Get to your first gated run"
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

    test "the shell's mobile drawer is a focus-contained dialog wired to its trigger",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # The hamburger announces what it controls and whether it's open; the
      # open/close JS commands keep aria-expanded accurate.
      [hamburger] = Regex.run(~r/<button[^>]*id="mobile-nav-open"[^>]*>/, html)
      assert hamburger =~ ~s(aria-controls="mobile-nav")
      assert hamburger =~ ~s(aria-expanded="false")

      # The drawer is a labelled modal dialog; focus_wrap contains Tab inside
      # it and DialogFocus returns focus to the hamburger on close (behavior
      # verified in the browser — the suite has no DOM).
      [drawer] = Regex.run(~r/<div[^>]*id="mobile-nav"[^>]*>/, html)
      assert drawer =~ ~s(role="dialog")
      assert drawer =~ ~s(aria-modal="true")
      assert drawer =~ ~s(phx-hook="DialogFocus")
      assert html =~ ~s(id="mobile-nav-wrap")
      assert html =~ ~s(phx-hook="Phoenix.FocusWrap")
    end

    test "a fresh account renders the setup checklist — ordered, one primary, team optional",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # The zero state is an ORDERED path to the first gated run: two
      # required connections + one optional invite — not three equal pillars.
      assert html =~ "Get to your first gated run"
      assert html =~ "Connect a runner"
      assert html =~ "Connect an LLM agent"
      # Step 3 teaches the payoff with a concrete, copy-pasteable prompt so a
      # fresh operator sees exactly what to ask — not just how to connect.
      assert html =~ "Ask your agent to run an action"
      assert html =~ "load, memory, disk, and any failed services"
      assert html =~ "Invite your team"
      assert html =~ "optional"
      # Step 1 is current — the page's ONE brand-filled action.
      assert html =~ ~p"/app/#{account}/runners/install"
      # The operational sections wait until setup resolves.
      refute html =~ "Recent runs"

      # No auto-minted install key — the checklist links to the install page,
      # which mints when the operator navigates into it.
      assert Emisar.Repo.all(Emisar.Runners.EnrollmentKey) == []
    end

    test "a runner alone keeps the checklist — step 1 done, agent step current", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "Get to your first gated run"
      assert html =~ "1 of 3 done"
      assert html =~ "1 runner connected"
      assert html =~ ~p"/app/#{account}/agents/connect"
      refute html =~ "Recent runs"
    end

    test "an installed but offline runner keeps step 1 incomplete with recovery copy",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "Get to your first gated run"
      # A stored runner row is not a connected runner: the step stays
      # incomplete and explains recovery instead of advancing the checklist
      # toward a first action that cannot dispatch.
      refute html =~ "1 of 3 done"
      refute html =~ "1 runner connected"
      assert html =~ "but offline right now"
      assert html =~ "Bring one back online, or connect another host."

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/runners"}']",
               "See runner status"
             )
    end

    test "a runner last seen an hour ago reads offline, not connected", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.mark_disconnected_at(runner, DateTime.add(DateTime.utc_now(), -3600))

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # A host that connected once and dropped an hour ago is stale state, not
      # a completed step — only live presence completes "Connect a runner".
      refute html =~ "1 runner connected"
      assert html =~ "but offline right now"
    end

    test "an issued key that never authenticated keeps the agent step incomplete",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id)

      {_raw, _key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # Minting a key proves nothing about the agent side: completion waits for
      # an observed authenticated MCP call, and the copy says what's missing.
      assert html =~ "1 of 3 done"
      refute html =~ "1 agent connected"
      assert html =~ "agent has made an authenticated call yet"
    end

    test "an authenticated agent call completes step 2 and activates the first-action step",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      Fixtures.ApiKeys.mark_used(key)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # An online action-bearing runner + a credential an agent has actually
      # used: both connections read done and the first-run prompt is usable.
      assert html =~ "2 of 3 done"
      assert html =~ "1 agent connected"
      assert html =~ "Ask your agent to run an action"
      assert html =~ "load, memory, disk, and any failed services"
      refute html =~ "Install a pack from the catalog"
    end

    test "actions advertised only by an offline runner don't count as ready", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Runners.create_runner(account_id: account.id)
      offline_runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Catalog.create_action(runner: offline_runner)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      Fixtures.ApiKeys.mark_used(key)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # The offline runner's leftover catalog rows can't back a dispatch — the
      # checklist asks for a pack on the runner that is actually online.
      assert html =~ "Install a pack from the catalog"
      refute html =~ "load, memory, disk, and any failed services"
    end

    test "a viewer sees truthful setup state but no setup actions", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Fixtures.Memberships.force_role(membership, "viewer")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      # A viewer can read every checklist fact, so the state is truthful — but
      # every setup action is gated to roles that can actually perform it.
      assert html =~ "Get to your first gated run"
      assert html =~ "Setup needs an operator role or above"
      refute html =~ ~p"/app/#{account}/runners/install"
    end

    test "renders the operational dashboard once a run exists", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(
          %{name: "Bot", scopes: ["actions:read"], runner_filter: []},
          subject
        )

      # The checklist owns the whole path to the first run; a landed run hands off.
      first_run(account, runner)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      refute html =~ "Get to your first gated run"
      # The runners pillar carries live state (one registered runner,
      # not connected in a test) and the runs section returns.
      assert html =~ "/ 1 connected"
      assert html =~ "Recent runs"

      # A solo account (just the owner) reports its honest member count and
      # nudges an invite — never the premature "Enable SSO"
      # SSO pitch, which waits for a team to exist.
      assert html =~ "1<span class=\"text-2xl text-zinc-500\"> member</span>"

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/team/invite"}']",
               "Invite team members"
             )

      refute html =~ "Enable SSO"
    end

    test "describes pending approvals as shared review work", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          args: %{},
          reason: "dashboard copy test",
          source: "operator"
        })

      {:ok, _request} = Emisar.Approvals.create_request(run, user.id, "confirm the change")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "Awaiting review"
      assert html =~ "1 pending decision"
      refute html =~ "waiting on you"
      refute html =~ "your approval"
    end

    test "a held runbook execution names its runbook, never a bare dash", %{conn: conn} do
      # A runbook_execution request carries no action_id, so reading one straight
      # off the context printed "—" as the row's whole identity — the operator
      # could not tell which of several held executions the row was.
      {conn, user, account} = register_and_log_in(conn)

      request =
        Fixtures.Approvals.create_execution_request(account, user, %{
          runbook_title: "Rotate the edge certificates"
        })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "Awaiting review"

      href = ~p"/app/#{account}/approvals/#{request.id}"
      row = lv |> element(~s(a[href="#{href}"])) |> render()

      assert row =~ "Rotate the edge certificates"
      refute row =~ "—"
    end

    test "the Team pillar pitches SSO once a real team exists", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      # A landed run puts the account on the operational dashboard (not the
      # checklist), so its pillars render.
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(
          %{name: "Bot", scopes: ["actions:read"], runner_filter: []},
          subject
        )

      first_run(account, runner)

      # A second member turns "solo" into a team.
      member = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      assert html =~ "2<span class=\"text-2xl text-zinc-500\"> members</span>"
      assert html =~ "Enable SSO"

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/team"}']",
               "Enable SSO"
             )

      refute html =~ "Invite team members"
    end

    test "the Team pillar flips to managing providers once SSO is live", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(
          %{name: "Bot", scopes: ["actions:read"], runner_filter: []},
          subject
        )

      first_run(account, runner)

      member = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

      Fixtures.SSO.create_identity_provider(account_id: account.id, enabled: true)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")

      # Nudging "Enable" at an account already on SSO reads as a bug — the
      # forward action is managing the providers, same destination.
      refute html =~ "Enable SSO"

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/team"}']",
               "Manage SSO providers"
             )
    end

    test "an operator's Team pillar reports the count and offers no SSO verb", %{conn: conn} do
      {_owner_conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(
          %{name: "Bot", scopes: ["actions:read"], runner_filter: []},
          subject
        )

      first_run(account, runner)

      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      Fixtures.SSO.create_identity_provider(account_id: account.id, enabled: true)

      {:ok, _lv, html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}")

      # The tile still reports where the team stands and still navigates to
      # Team; what it must not do is pitch a verb this role cannot perform.
      assert html =~ "2<span class=\"text-2xl text-zinc-500\"> members</span>"
      refute html =~ "Manage SSO providers"
      refute html =~ "Enable SSO"

      # With no verb to offer, the last line is a plain fact instead — the
      # answer to the question every lock tooltip on the console raises.
      assert html =~ "1 owner or admin"
    end

    test "the operator's Team pillar counts every owner and admin", %{conn: conn} do
      {_owner_conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")
      {:ok, _raw, _key} = Emisar.ApiKeys.create_key(%{name: "Bot"}, subject)
      first_run(account, runner)

      Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      # The finance seat manages no team, so it is a member and not a manager.
      Fixtures.Memberships.create_membership(account_id: account.id, role: "billing_manager")

      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      {:ok, _lv, html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}")

      assert html =~ "4<span class=\"text-2xl text-zinc-500\"> members</span>"
      assert html =~ "2 owners and admins"
    end

    test "both connected but no advertised actions: the checklist requires a catalog pack first",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _raw, key} =
        Emisar.ApiKeys.create_key(
          %{name: "Bot", scopes: ["actions:read"], runner_filter: []},
          subject
        )

      Fixtures.ApiKeys.mark_used(key)

      # Both connections exist, but the runner cannot execute anything yet. The
      # checklist replaces the unusable prompt with the missing setup action.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "Get to your first gated run"
      assert html =~ "needs at least one action pack"
      assert html =~ "Install a pack from the catalog"
      assert html =~ "not advertising any actions yet"
      assert html =~ "emisar pack suggest"
      assert html =~ "emisar pack install"
      refute html =~ "load, memory, disk, and any failed services"

      assert has_element?(
               lv,
               "a[href='#{~p"/packs"}']",
               "Browse the pack catalog"
             )

      # Once the runner advertises an action, the first-run prompt becomes
      # truthful and usable without requiring a page refresh.
      Fixtures.Catalog.create_action(runner: runner)

      send(lv.pid, %{
        event: "presence_diff",
        payload: %{joins: %{runner.id => %{metas: [%{}]}}, leaves: %{}}
      })

      send(lv.pid, :refresh_dashboard)
      html = render(lv)
      assert html =~ "Ask your agent to run an action"
      assert html =~ "load, memory, disk, and any failed services"
      refute html =~ "Install a pack from the catalog"
      refute html =~ "emisar pack suggest"

      # The first run hands off to the pillars — the checklist is gone.
      first_run(account, runner)
      {:ok, _lv2, html2} = live(conn, ~p"/app/#{account}")
      refute html2 =~ "Get to your first gated run"
      assert html2 =~ "Recent runs"
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

    # the dashboard is a read-only triage screen: the setup checklist's
    # actions are plain `<.link navigate>`s to real routes, not server-driven
    # actions; the LV defines no mutating `handle_event`, so there's nothing
    # to abuse.
    test "setup checklist actions are plain navigation links to real routes (read-only)",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/runners/install"}']",
               "Connect a runner"
             )

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/agents/connect"}']",
               "Connect an agent"
             )

      assert has_element?(
               lv,
               "a[href='#{~p"/app/#{account}/settings/team/invite"}']",
               "Send an invite"
             )
    end

    test "runner topology broadcasts schedule a debounced fleet refresh", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}")
      assert html =~ "Get to your first gated run"

      # A runner registers elsewhere; the dashboard hears the topology-changing
      # Presence diff and arms a debounced runner-only refresh. Inject the timer
      # directly so the checklist flips without waiting in the test.
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      send(lv.pid, %{
        event: "presence_diff",
        payload: %{joins: %{runner.id => %{metas: [%{}]}}, leaves: %{}}
      })

      send(lv.pid, :refresh_dashboard)
      assert render(lv) =~ "1 of 3 done"

      # Unrelated message shapes are ignored, never a crash.
      send(lv.pid, :stray_message)
      assert render(lv) =~ "1 of 3 done"
    end

    test "a run event refreshes only the recent runs it renders", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      # The header digest is DERIVED from the rows just read (so it can only ever
      # describe them — §7.36), which also costs no second windowed read.
      assert refresh_query_count(lv, {:run_updated, Ecto.UUID.generate()}) == 3
    end

    test "an approval event refreshes only the fixed five-row queue snippet", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      assert refresh_query_count(lv, {:approval_updated, Ecto.UUID.generate()}) == 3
    end

    test "a runner topology event refreshes only fleet and advertised-action facts", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      event = %{
        event: "presence_diff",
        payload: %{joins: %{Ecto.UUID.generate() => %{metas: [%{}]}}, leaves: %{}}
      }

      assert refresh_query_count(lv, event) == 3
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

    # when a runner advertises a pack version no operator has trusted yet
    # (`count_pack_versions_needing_decision > 0`), the dashboard surfaces the
    # amber packs-decision banner linking to the Packs page (dispatch is
    # blocked against those packs until an admin resolves the decision).
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
          "packs" => %{
            "custom" => %{
              "version" => "1.0",
              "hash" => Fixtures.Catalog.pack_hash("PENDING")
            }
          },
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

      assert html =~ "need"
      assert html =~ "a decision"
      # …and it links to the Packs page where the admin resolves it.
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/packs"}']")
    end
  end

  describe "a billing_manager's console" do
    test "redirects to billing, where the nav offers only what the role can open", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)

      member = Emisar.Fixtures.Users.create_user() |> Emisar.Fixtures.Users.confirm_user()

      Emisar.Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "billing_manager"
      )

      conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

      # The dashboard is runner onboarding + dispatch a finance-only seat can't
      # perform (every tile reads :unauthorized), so /app bounces to billing —
      # the seat's actual job — instead of a dead-end first-run checklist.
      billing = ~p"/app/#{account}/settings/billing"
      assert {:error, {:live_redirect, %{to: ^billing}}} = live(conn, ~p"/app/#{account}")

      # And on billing the nav still offers only what the role can open.
      {:ok, lv, _html} = live(conn, billing)

      # The seat's three surfaces: Billing is its job, the roster is every
      # member's floor, and Audit opens onto the billing slice of the trail
      # (`Audit.Authorizer.for_subject/2` withholds the rest of the rows).
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/settings/billing"}']")
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/settings/team"}']")
      assert has_element?(lv, "a[href='#{~p"/app/#{account}/audit"}']")

      # The sections the role holds no view permission for are gone.
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/runbooks"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/policies"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/runs"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/runners"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/packs"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/approvals"}']")
      refute has_element?(lv, "a[href='#{~p"/app/#{account}/agents"}']")
    end
  end

  # A landed run pushes an account past the onboarding checklist into the
  # operational dashboard — the checklist owns everything up to the first run.
  defp first_run(account, runner) do
    {:ok, _run} =
      Emisar.Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "first run",
        source: "operator"
      })
  end

  defp refresh_query_count(lv, event) do
    test_pid = self()
    handler = make_ref()

    :telemetry.attach(
      handler,
      [:emisar, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:repo_query, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    send(lv.pid, event)
    _ = render(lv)
    _ = drain_repo_query_count(lv.pid)

    send(lv.pid, :refresh_dashboard)
    _ = render(lv)
    query_count = drain_repo_query_count(lv.pid)
    :ok = :telemetry.detach(handler)
    query_count
  end

  defp drain_repo_query_count(pid, count \\ 0) do
    receive do
      {:repo_query, ^pid} -> drain_repo_query_count(pid, count + 1)
      {:repo_query, _other_pid} -> drain_repo_query_count(pid, count)
    after
      0 -> count
    end
  end
end
