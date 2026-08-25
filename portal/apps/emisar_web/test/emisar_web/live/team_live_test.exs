defmodule EmisarWeb.TeamLiveTest do
  @moduledoc """
  Regression test for #112: TeamLive showed "Only owners and admins can
  invite" to a user whose role WAS owner because `can_manage?(assigns)`
  was being called with the bare assigns map instead of a socket-shaped
  struct and the pattern match failed.
  """

  use EmisarWeb.ConnCase, async: true
  import Swoosh.TestAssertions

  defp subscribe_team(account) do
    assert Emisar.Accounts.subscribe_account_team(account.id) == :ok
  end

  defp assert_team_broadcast(lv, event, user_id) do
    assert_receive {:list_changed, :team, ^event, ^user_id}
    render(lv)
  end

  describe "GET /app/settings/team as an owner" do
    test "the roster offers an Invite member action, not the read-only banner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "Invite member"
      # The invite form itself lives on its own page now, not inline on the roster.
      refute html =~ "Send invite"
      refute html =~ "Only owners and admins can invite"
    end

    test "the roster has one name-or-email search plus role and status filters", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      kept_user = Fixtures.Users.create_user(full_name: "Filter Finch")
      gone_user = Fixtures.Users.create_user(full_name: "Hidden Harper")

      kept =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: kept_user.id
        )

      gone =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: gone_user.id
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "#members-filter input[name='name_or_email']")
      assert has_element?(lv, "#members-filter select[name='role']")
      assert has_element?(lv, "#members-filter select[name='status']")

      assert has_element?(
               lv,
               "#members-filter option[value='billing_manager']",
               "Billing manager"
             )

      assert has_element?(
               lv,
               "#members-filter option[value='pending_invitation']",
               "Pending invitation"
             )

      lv
      |> form("#members-filter", %{"name_or_email" => "FILTER fin"})
      |> render_change()

      assert_patched(lv, ~p"/app/#{account}/settings/team?name_or_email=FILTER+fin")
      assert has_element?(lv, "#member-name-#{kept.id}")
      refute has_element?(lv, "#member-name-#{gone.id}")
    end

    test "role and status filters combine", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      suspended_viewer =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
        |> Fixtures.Memberships.suspend_membership()

      active_viewer =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      suspended_admin =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
        |> Fixtures.Memberships.suspend_membership()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      lv
      |> form("#members-filter", %{"role" => "viewer", "status" => "suspended"})
      |> render_change()

      assert has_element?(lv, "#member-name-#{suspended_viewer.id}")
      refute has_element?(lv, "#member-name-#{active_viewer.id}")
      refute has_element?(lv, "#member-name-#{suspended_admin.id}")
    end

    test "a filter miss keeps the controls and clear action", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/settings/team?name_or_email=missing-member")

      assert html =~ "No members match these filters"
      assert html =~ "Try another name, role, or status."

      assert has_element?(
               lv,
               "#members-filter input[name='name_or_email'][value='missing-member']"
             )

      assert has_element?(lv, "#members-filter select[name='role']")
      assert has_element?(lv, "#members-filter select[name='status']")
      assert has_element?(lv, "a", "Clear filters")
      refute html =~ "No team members yet."
    end

    test "pack grant fields explain when the admin's own pack access is limited", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)
      admin = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, restricted} =
        Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, ["postgres"])

      Fixtures.Memberships.force_runner_access(membership, restricted)

      {:ok, lv, html} =
        build_conn()
        |> log_in_user(admin)
        |> live(~p"/app/#{account}/settings/team/invite")

      refute html =~ "You can grant only packs within your own access."

      changed =
        lv
        |> form("#invite_form", %{"invite" => %{"runner_access_mode" => "all"}})
        |> render_change()

      assert changed =~ "You can grant only packs within your own access."
    end

    test "pack grant fields stay quiet for an unrestricted owner", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      changed =
        lv
        |> form("#invite_form", %{"invite" => %{"runner_access_mode" => "all"}})
        |> render_change()

      refute changed =~ "You can grant only packs within your own access."
    end

    test "the Security rail is SSO's one console door (its nav item is gone)", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Free plan, no provider: SSO is plan-gated, shown as a quiet line (no pill,
      # no link — Billing is in the nav). No provider to list yet.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Available on the Team and Enterprise plans"

      # With the plan (still no provider), the door becomes the real Add button
      # into /new — the plan gate is cleared.
      Fixtures.Accounts.create_subscription(account, "team")
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Add provider"
      assert html =~ ~p"/app/#{account}/settings/sso/new"
      refute html =~ "Available on the Team and Enterprise plans"

      # The card's anchor id is a deep-link contract: /settings/sso redirects to
      # /settings/team#single-sign-on, and /docs/sso sends operators there.
      assert has_element?(lv, "#single-sign-on")
    end

    test "pending SSO access requests surface on Team, and approving clears one", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      request =
        Fixtures.SSO.create_link_request(
          provider: provider,
          full_name: "Dana Ops",
          email: "dana@corp.test"
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Pending access requests"
      assert html =~ "Dana Ops"
      assert html =~ "dana@corp.test"
      assert has_element?(lv, "#team-primary-column > #pending-access-requests")

      assert has_element?(
               lv,
               "#team-primary-column > #pending-access-requests + #members-section"
             )

      # Approve is a styled confirm modal (not a native data-confirm); its Confirm
      # dispatches approve_request. Provisioning drops the request from the list —
      # the only one, so the whole queue clears (name lingers in the flash).
      assert has_element?(lv, "#approve-request-#{request.id}")

      render_click(lv, "approve_request", %{
        "id" => request.id,
        "runner_access_mode" => "none"
      })

      refute render(lv) =~ "Pending access requests"
      assert Emisar.Repo.reload(request) == nil
    end

    test "an unverified OIDC email is shown only as context, never as an existing-account match",
         %{
           conn: conn
         } do
      {conn, _owner, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.Users.create_user(email: "unverified-match@corp.test")

      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      assert {:ok, request} =
               Emisar.SSO.Provisioning.capture_link_request(
                 provider,
                 "okta|unverified-match",
                 member.email,
                 "Unverified Match",
                 %{"email" => member.email},
                 :oidc
               )

      assert is_nil(request.matched_user_id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ member.email
      refute html =~ "Existing account"
    end

    test "the pending-request form reaches the runner access change handler", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      request = Fixtures.SSO.create_link_request(provider: provider, full_name: "Dana Ops")
      _runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      form = "#approve-request-#{request.id}"

      lv
      |> form(form, %{"runner_access_mode" => "restricted"})
      |> render_change()

      assert has_element?(lv, "#{form} input[name='scope[]']")
    end

    test "clearing the last pending-request runner scope keeps it cleared", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      request = Fixtures.SSO.create_link_request(provider: provider, full_name: "Dana Ops")
      _runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      form = "#approve-request-#{request.id}"

      render_change(lv, "approval_access_changed", %{
        "_request_id" => request.id,
        "runner_access_mode" => "restricted",
        "scope" => ["group:database"]
      })

      assert has_element?(lv, "#{form} input[value='group:database']:checked")

      html =
        render_change(lv, "approval_access_changed", %{
          "_request_id" => request.id,
          "runner_access_mode" => "restricted"
        })

      refute has_element?(lv, "#{form} input[value='group:database']:checked")
      assert html =~ "Choose at least one runner group or runner for selected access."
    end

    test "clearing the last pending-request pack scope names the error at the picker", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      request = Fixtures.SSO.create_link_request(provider: provider, full_name: "Dana Ops")
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      Fixtures.Catalog.create_action(runner: runner, action_id: "pg.up", pack_id: "postgres")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      form = "#approve-request-#{request.id}"

      revealed =
        render_change(lv, "approval_access_changed", %{
          "_request_id" => request.id,
          "runner_access_mode" => "all",
          "pack_access_mode" => "restricted"
        })

      refute revealed =~ "Choose at least one pack"

      render_change(lv, "approval_access_changed", %{
        "_request_id" => request.id,
        "runner_access_mode" => "all",
        "pack_access_mode" => "restricted",
        "pack_scope" => ["pack:postgres"]
      })

      assert has_element?(lv, "#{form} input[value='pack:postgres']:checked")

      cleared =
        render_change(lv, "approval_access_changed", %{
          "_request_id" => request.id,
          "runner_access_mode" => "all",
          "pack_access_mode" => "restricted"
        })

      refute has_element?(lv, "#{form} input[value='pack:postgres']:checked")
      assert cleared =~ "Choose at least one pack for selected pack access."
    end

    test "the connection lists in the Security panel with the sign-in link", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Okta prod")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      # The connection row links straight to its detail page; the branded sign-in
      # link shows once a connection exists.
      assert html =~ "Okta prod"
      assert html =~ ~p"/app/#{account}/settings/sso/#{provider.id}"
      assert html =~ "Team sign-in link"
      # No leading unlabeled dot: the row already says "Disabled" in words, and a
      # dot beside sync metadata would report a different dimension (§7.32). The
      # trailing navigation chevron is the row's affordance and stays.
      refute has_element?(lv, "#sso-provider-#{provider.id} > [aria-hidden=true]:first-child")
    end

    test "SSO enforcement is a subsection above the team sign-in link", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      Fixtures.SSO.create_identity_provider(account_id: account.id)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "#single-sign-on [data-role='require-sso-section']")
      assert has_element?(lv, "#single-sign-on [data-role='team-sign-in-section']")
      assert {require_position, _length} = :binary.match(html, "require-sso-section")
      assert {sign_in_position, _length} = :binary.match(html, "team-sign-in-section")
      assert require_position < sign_in_position
      assert has_element?(lv, "#single-sign-on #require-sso")
    end

    test "a downgraded plan still shows pending requests — dismissing one needs no plan", %{
      conn: conn
    } do
      # The owner can no longer APPROVE these (that grants access, and the plan
      # gates it), but they must still see the queue to turn people away. Hiding
      # it left requests piling up where nobody could act on them.
      {conn, _user, account} = register_and_log_in(conn)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      Fixtures.SSO.create_link_request(provider: provider, full_name: "Dana Ops")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Pending access requests"
      assert html =~ "Dana Ops"
    end

    test "pending requests stay hidden without manage_sso", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      Fixtures.SSO.create_link_request(provider: provider, full_name: "Dana Ops")

      {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Fixtures.Memberships.force_role(membership, "viewer")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      refute html =~ "Pending access requests"
      refute html =~ "Dana Ops"
    end
  end

  describe "GET /app/settings/team/invite" do
    test "renders the invite form with each role explained", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      assert html =~ "Send invite"
      # Each assignable role is explained, not just named — assigning one is a
      # privilege grant, so the picker itself carries the description.
      assert html =~ "Read-only across runs"
      assert html =~ "Dispatches actions and approves them"
      assert has_element?(lv, "input[name='invite[runner_access_mode]'][value='none']:checked")
      assert html =~ "New members start with no access"
    end

    test "an invalid email renders inline on the field, not in a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => "not-an-email", "role" => "operator"}})
        |> render_submit()

      # Inline field error (rendered by <.input>/<.error> under the input)…
      assert html =~ "must have the @ sign and no spaces"
      # …and no flash banner — the bad address never reaches the mailer.
      refute html =~ "Could not send invitation"
      refute html =~ "Invitation sent"
    end

    test "a successful invite lands on the success step with next actions", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      html =
        lv
        |> form("#invite_form", %{
          "invite" => %{"email" => "newbie@example.com", "role" => "operator"}
        })
        |> render_submit()

      assert html =~ "Invitation sent"
      assert html =~ "The join link is on its way"
      assert html =~ "newbie@example.com"
      assert html =~ "Operator"
      assert html =~ "None"
      assert html =~ "Invite another"
      assert html =~ "View members"
      assert html =~ "What happens next"

      assert_email_sent(fn sent ->
        sent.to == [{"", "newbie@example.com"}] and sent.text_body =~ "/accept_invitation/"
      end)

      # "Invite another" resets to a clean form on the same page.
      reset = render_click(lv, "invite_another", %{})
      assert reset =~ "Send invite"
      refute reset =~ "Invitation sent"
    end

    test "the completion receipt reports the persisted selected runner and pack access", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)

      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "db-primary", group: "db")

      Fixtures.Catalog.create_trusted_pack_version(account_id: account.id, pack_id: "postgres")
      Fixtures.Catalog.create_action(runner: runner, action_id: "pg.up", pack_id: "postgres")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      lv
      |> form("#invite_form", %{
        "invite" => %{"runner_access_mode" => "restricted"}
      })
      |> render_change()

      lv
      |> form("#invite_form", %{
        "invite" => %{
          "runner_access_mode" => "restricted",
          "scope" => ["runner:#{runner.id}"]
        }
      })
      |> render_change()

      lv
      |> form("#invite_form", %{
        "invite" => %{
          "runner_access_mode" => "restricted",
          "scope" => ["runner:#{runner.id}"],
          "pack_access_mode" => "restricted"
        }
      })
      |> render_change()

      html =
        lv
        |> form("#invite_form", %{
          "invite" => %{
            "email" => "scoped-receipt@example.com",
            "role" => "viewer",
            "runner_access_mode" => "restricted",
            "scope" => ["runner:#{runner.id}"],
            "pack_access_mode" => "restricted",
            "pack_scope" => ["pack:postgres"]
          }
        })
        |> render_submit()

      assert html =~ "scoped-receipt@example.com"
      assert html =~ "Viewer"
      assert html =~ "db-primary"
      assert html =~ "postgres"

      {:ok, user} = Emisar.Users.fetch_user_by_email("scoped-receipt@example.com")
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      assert Emisar.Accounts.runner_access_for_membership(account.id, membership.id) ==
               %Emisar.Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: [],
                 runner_ids: [runner.id],
                 pack_mode: :restricted,
                 pack_ids: ["postgres"]
               }
    end

    test "selected runner access is required and persisted with the invitation", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      _db = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      _web = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      changed =
        lv
        |> form("#invite_form", %{
          "invite" => %{"runner_access_mode" => "restricted"}
        })
        |> render_change()

      refute changed =~ "Choose at least one runner group or runner"
      assert length(Regex.scan(~r/>Selected runners</, changed)) == 1

      invalid =
        lv
        |> form("#invite_form", %{
          "invite" => %{
            "email" => "scoped@example.com",
            "role" => "operator",
            "runner_access_mode" => "restricted",
            "scope" => []
          }
        })
        |> render_submit()

      assert invalid =~ "Choose at least one runner group or runner"

      lv
      |> form("#invite_form", %{
        "invite" => %{
          "email" => "scoped@example.com",
          "role" => "operator",
          "runner_access_mode" => "restricted",
          "scope" => ["group:database"]
        }
      })
      |> render_submit()

      {:ok, user} = Emisar.Users.fetch_user_by_email("scoped@example.com")
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      assert Emisar.Accounts.runner_access_for_membership(account.id, membership.id) ==
               %Emisar.Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: ["database"],
                 runner_ids: []
               }
    end

    test "a runner retired while composing fails inline, keeping the typed values", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      # Reveal the picker, then retire the runner behind the open form — its
      # options were loaded on mount, so only the write's own revalidation can
      # catch the stale pick.
      lv
      |> form("#invite_form", %{"invite" => %{"runner_access_mode" => "restricted"}})
      |> render_change()

      Fixtures.Runners.mark_deleted(runner)

      html =
        lv
        |> form("#invite_form", %{
          "invite" => %{
            "email" => "stale@example.com",
            "role" => "operator",
            "runner_access_mode" => "restricted",
            "scope" => ["runner:#{runner.id}"]
          }
        })
        |> render_submit()

      assert html =~ "Choose at least one runner group or runner"
      assert html =~ "stale@example.com"
      refute html =~ "Invitation sent"
      assert Emisar.Users.fetch_user_by_email("stale@example.com") == {:error, :not_found}
    end

    test "a viewer hitting the invite route directly is refused (IL-15)", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{name: "ViewerInvite"}})
      {:ok, m} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Fixtures.Memberships.force_role(m, "viewer")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team/invite")

      # The route is reachable, but the domain-gated view refuses to compose an
      # invite for a viewer (no form) and explains who can.
      assert html =~ "Ask an owner or admin to add someone"
      refute html =~ "Send invite"

      # Forging the submit event past the missing form lands on the domain gate.
      email = "forged-#{System.unique_integer([:positive])}@example.com"

      assert render_submit(lv, "invite", %{"invite" => %{"email" => email, "role" => "owner"}}) =~
               "Only owners and admins can invite members."

      assert Emisar.Users.fetch_user_by_email(email) == {:error, :not_found}
    end
  end

  describe "resend confirmation (self)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "an unconfirmed user can resend their own confirmation email", %{
      conn: conn,
      user: user,
      account: account
    } do
      # TeamLive defines no `resend_confirmation` handler — the row's button is
      # served by the portal-wide `:email_confirmation` on_mount hook (the same
      # one behind the verify-email banner), which owns the send + rate-limit. A
      # successful click flashing the hook's copy proves the global handler, not
      # TeamLive, fielded the event.
      # Simulate the signed-up-but-unconfirmed state (register_and_log_in
      # confirms by default).
      {:ok, _} = user |> Ecto.Changeset.change(confirmed_at: nil) |> Emisar.Repo.update()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Resend email"

      # Scoped to the roster: the portal-wide verify-email strip offers the same
      # remedy in the same words on this very page, so an unscoped selector
      # matches two buttons.
      roster_resend = "#members button.border-zinc-800[phx-click='resend_confirmation']"
      assert has_element?(lv, roster_resend, "Resend email")

      html = lv |> element(roster_resend) |> render_click()
      assert html =~ "Confirmation email sent"
    end

    test "a confirmed user sees no resend button", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      refute html =~ "Resend email"
    end
  end

  describe "GET /app/settings/team as a viewer" do
    test "shows the read-only banner and no invite action", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{name: "ViewerOrg"}})

      {:ok, m} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Fixtures.Memberships.force_role(m, "viewer")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "Only owners and admins can invite"
      refute html =~ "Invite member"
    end

    test "shows connection availability without exposing connection details", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")

      _provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Private IdP")

      {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Fixtures.Memberships.force_role(membership, "viewer")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      # The state reaches them as the locked value every other setting on this
      # page uses, not as a sentence about who outranks them.
      assert has_element?(lv, "#sso-connections-lock-tt", "Configured")
      refute has_element?(lv, "#sso-connections-lock-tt", "Not configured")
      assert has_element?(lv, "#sso-connections-lock", "Only owners and admins can change this.")
      refute html =~ "Configured — owners and admins manage connections."
      refute html =~ "Not configured — members sign in with a magic link."
      refute html =~ "Private IdP"
    end

    test "an unconfigured account reads as Not configured, still locked", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      Fixtures.Memberships.force_role(membership, "viewer")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "#sso-connections-lock-tt", "Not configured")
    end
  end

  describe "a non-manager (billing manager / operator / viewer) sees the roster read-only" do
    setup %{conn: conn} do
      # An owner with the account + a teammate to render in the roster, then a
      # second member we log in AS to observe the read-only view.
      {_owner_conn, _owner, account} =
        register_and_log_in(conn, %{account: %{name: "ReadOnlyOrg"}})

      teammate = Fixtures.Users.create_user(%{full_name: "Teammate Tess"})

      teammate_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: teammate.id,
          role: "admin"
        )

      %{account: account, teammate: teammate, teammate_membership: teammate_membership}
    end

    for role <- ~w(operator viewer) do
      test "an #{role} reads the roster but every management control is hidden", %{
        account: account,
        teammate: teammate,
        teammate_membership: teammate_membership
      } do
        member = Fixtures.Users.create_user()

        _ =
          Fixtures.Memberships.create_membership(
            account_id: account.id,
            user_id: member.id,
            role: unquote(role)
          )

        {:ok, lv, html} =
          build_conn() |> log_in_user(member) |> live(~p"/app/#{account}/settings/team")

        # The roster IS visible.
        assert html =~ "Teammate Tess"
        assert html =~ teammate.email

        # …but no management surface: no invite, no Actions menu, no role
        # dropdown, no per-row management events on the teammate's row.
        refute html =~ "Invite member"
        refute html =~ "Send invite"
        refute has_element?(lv, "summary", "Actions")

        refute has_element?(lv, "##{"change-role-#{teammate_membership.id}-operator"}")

        # The read-only note names their role and points them at who can manage.
        # It renders the role's LABEL, so `billing_manager` reads as a phrase
        # rather than leaking the atom's underscore.
        assert html =~ "Only owners and admins can invite or manage members."
        assert html =~ "Your role: #{Emisar.Auth.role_label(unquote(role))}"

        # The roster offers no jump into a TEAMMATE's audit trail — only into
        # your own. (A manager's per-row audit item lives in the Actions menu,
        # which this role doesn't get at all.)
        refute has_element?(
                 lv,
                 "a[href*='actor_id=#{teammate.id}']",
                 "View activity"
               )

        assert has_element?(lv, "a[href*='actor_id=#{member.id}']", "View activity")
      end
    end

    # The finance seat reads the roster like any other non-manager, but its
    # audit reach is the billing slice — so a person-filtered trail would always
    # be empty, and it gets no jump into one at all, not even its own row.
    test "a billing manager reads the roster and is offered no activity jump", %{
      account: account,
      teammate: teammate,
      teammate_membership: teammate_membership
    } do
      member = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "billing_manager"
      )

      {:ok, lv, html} =
        build_conn() |> log_in_user(member) |> live(~p"/app/#{account}/settings/team")

      assert html =~ "Teammate Tess"
      assert html =~ teammate.email

      refute html =~ "Invite member"
      refute html =~ "Send invite"
      refute has_element?(lv, "summary", "Actions")
      refute has_element?(lv, "##{"change-role-#{teammate_membership.id}-operator"}")

      assert html =~ "Only owners and admins can invite or manage members."
      assert html =~ "Your role: Billing manager"

      refute has_element?(lv, "a[href*='actor_id=#{teammate.id}']", "View activity")
      refute has_element?(lv, "a[href*='actor_id=#{member.id}']", "View activity")
    end

    test "a teammate's activity facts are hidden; your own row keeps them", %{
      account: account,
      teammate: teammate,
      teammate_membership: teammate_membership
    } do
      member = Fixtures.Users.create_user(%{full_name: "Reader Rae"})

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(member) |> live(~p"/app/#{account}/settings/team")

      teammate_metadata =
        lv |> element("#member-metadata-#{teammate_membership.id}") |> render()

      # When and how recently a colleague signs in is an administrative fact —
      # their identity still reads in full, and the middot goes with the facts.
      assert teammate_metadata =~ teammate.email
      refute teammate_metadata =~ "joined"
      refute teammate_metadata =~ "active"
      refute teammate_metadata =~ "·"

      own_metadata = lv |> element("#member-metadata-#{membership.id}") |> render()

      assert own_metadata =~ member.email
      assert own_metadata =~ "joined"
      assert own_metadata =~ "last active"
    end

    test "the permission note opens the page, with the docs link still the intro's tail", %{
      account: account
    } do
      member = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

      {:ok, lv, html} =
        build_conn() |> log_in_user(member) |> live(~p"/app/#{account}/settings/team")

      # One paragraph, in this order: what the page is, who may change it, docs.
      assert has_element?(
               lv,
               "p",
               ~r/who can dispatch, approve,\s+and configure\.\s+Only owners and admins can invite or manage members\.\s+Your role: Operator\.\s+Team & access docs/s
             )

      # Moved, not duplicated — the footer under the roster is gone.
      assert length(Regex.scan(~r/Only owners and admins can invite or manage members\./, html)) ==
               1
    end

    test "the permission note keeps the viewer's role when filters hide their row", %{
      account: account
    } do
      viewer = Fixtures.Users.create_user(full_name: "Reader Rae")

      viewer_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, html} =
        build_conn()
        |> log_in_user(viewer)
        |> live(~p"/app/#{account}/settings/team?role=owner")

      assert html =~ "Your role: Viewer"
      refute has_element?(lv, "#member-name-#{viewer_membership.id}")
      assert has_element?(lv, "#members-filter option[value='owner'][selected]")
    end
  end

  describe "a non-manager's crafted management events are denied (IL-15)" do
    setup %{conn: conn} do
      # An owner account; a viewer we log in AS; a teammate to target.
      {_owner_conn, _owner, account} =
        register_and_log_in(conn, %{account: %{name: "CraftedOrg"}})

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      target = Fixtures.Users.create_user()

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      viewer_conn = build_conn() |> log_in_user(viewer)
      {:ok, lv, _html} = live(viewer_conn, ~p"/app/#{account}/settings/team")

      %{
        conn: viewer_conn,
        lv: lv,
        account: account,
        target: target,
        target_membership: target_membership
      }
    end

    test "change_role is refused and the role is untouched", %{
      lv: lv,
      target_membership: target_membership
    } do
      html =
        render_click(lv, "change_role", %{
          "membership_id" => target_membership.id,
          "role" => "admin"
        })

      assert html =~ "Only owners and admins can manage members."
      assert Emisar.Repo.reload!(target_membership).role == :operator
    end

    test "remove is refused and the membership survives", %{
      lv: lv,
      target_membership: target_membership
    } do
      html = render_click(lv, "remove", %{"membership_id" => target_membership.id})

      assert html =~ "Only owners and admins can manage members."
      refute Emisar.Repo.reload!(target_membership).deleted_at
    end

    test "suspend is refused and the member stays active", %{
      lv: lv,
      target_membership: target_membership
    } do
      html = render_click(lv, "suspend", %{"membership_id" => target_membership.id})

      assert html =~ "Only owners and admins can manage members."
      refute Emisar.Repo.reload!(target_membership).disabled_at
    end

    test "save_edit (admin name change) is refused and the name is untouched", %{
      lv: lv,
      target: target,
      target_membership: target_membership
    } do
      # The edit form is never in a viewer's DOM (no Actions menu), so push the
      # event directly — the server gate must still refuse it.
      html =
        render_submit(lv, "save_edit", %{
          "membership_id" => target_membership.id,
          "user" => %{"full_name" => "Hijacked Name"}
        })

      assert html =~ "Only owners and admins can manage members."
      assert Emisar.Repo.reload!(target).full_name == target.full_name
    end

    test "end_sessions is refused", %{lv: lv, target_membership: target_membership} do
      html = render_click(lv, "end_sessions", %{"membership_id" => target_membership.id})

      assert html =~ "Only owners and admins can manage members."
    end

    test "the focused reset route is refused server-side", %{
      conn: conn,
      account: account,
      target: target,
      target_membership: target_membership
    } do
      enroll_mfa(target)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 conn,
                 ~p"/app/#{account}/settings/team/#{target_membership.id}/reset_2fa"
               )

      assert to == ~p"/app/#{account}/settings/team"

      assert Emisar.Repo.reload!(target).mfa_enabled_at
    end

    test "resend_invitation is refused server-side", %{
      lv: lv,
      target_membership: target_membership
    } do
      html = render_click(lv, "resend_invitation", %{"membership_id" => target_membership.id})

      assert html =~ "Only owners and admins can invite members."
      refute Emisar.Repo.reload!(target_membership).invitation_token_digest
    end

    test "save_scopes is refused via the Accounts gate, access unchanged", %{
      lv: lv,
      target_membership: target_membership
    } do
      html =
        render_submit(lv, "save_scopes", %{
          "membership_id" => target_membership.id,
          "runner_access_mode" => "none"
        })

      # The Accounts context denies with :unauthorized; the LV maps it to the same
      # membership-management flash, and access is unchanged.
      assert html =~ "Only owners and admins can manage members."

      assert Emisar.Accounts.runner_access_for_membership(
               target_membership.account_id,
               target_membership.id
             ) == Emisar.Accounts.RunnerAccess.all()
    end
  end

  describe "runner-scope editor (#238)" do
    # The seat's access is structurally nothing, so the roster states the cleared
    # value and drops the verb rather than opening an editor that cannot save.
    test "a billing manager is offered no Set access verb, and the event is refused anyway", %{
      conn: conn
    } do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "FinanceOrg"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      finance =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "billing_manager")

      operator = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      # The verb exists on the page — for the operator, not the finance seat.
      assert html =~ "Set access"

      assert has_element?(
               lv,
               "[phx-click='start_scope_edit'][phx-value-membership_id='#{operator.id}']"
             )

      refute has_element?(
               lv,
               "[phx-click='start_scope_edit'][phx-value-membership_id='#{finance.id}']"
             )

      # Hiding it is never the check (IL-15) — the crafted event is refused too.
      assert render_click(lv, "start_scope_edit", %{"membership_id" => finance.id}) =~
               "A billing manager has no runner or pack access."

      assert Emisar.Accounts.update_membership_runner_access(
               Fixtures.Memberships.fetch_membership(account.id, finance.user_id),
               Emisar.Accounts.RunnerAccess.all(),
               subject
             ) == {:error, :role_carries_no_runner_access}
    end

    test "owner can save a group + an individual runner (in another group)", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg"}})

      # An invited admin we'll scope.
      email = "scoped-#{System.unique_integer([:positive])}@example.com"

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      {:ok, %{membership: m}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      # A whole group, plus one runner from a DIFFERENT group (picking a runner
      # inside the chosen group would be redundant — it collapses to the group).
      _dba = Fixtures.Runners.create_runner(account_id: account.id, name: "r1", group: "dba")
      web = Fixtures.Runners.create_runner(account_id: account.id, name: "r2", group: "web")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "runners:"

      # Open the inline editor for the invited admin.
      render_click(lv, "start_scope_edit", %{"membership_id" => m.id})

      render_submit(
        element(lv, "form[phx-submit='save_scopes']"),
        %{
          "membership_id" => m.id,
          "runner_access_mode" => "restricted",
          "scope" => ["group:dba", "runner:#{web.id}"]
        }
      )

      assert Emisar.Accounts.runner_access_for_membership(account.id, m.id) ==
               %Emisar.Accounts.RunnerAccess{
                 mode: :restricted,
                 groups: ["dba"],
                 runner_ids: [web.id]
               }
    end

    test "an emptied pack selection is named at the picker, not in a flash", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "PackErrOrg"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "packerr-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: m}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "r1", group: "dba")
      Fixtures.Catalog.create_action(runner: runner, action_id: "pg.up", pack_id: "postgres")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      render_click(lv, "start_scope_edit", %{"membership_id" => m.id})
      form = "form[phx-submit='save_scopes']"

      # Revealing an empty pack picker accuses nobody.
      revealed =
        render_change(lv, "scope_changed", %{
          "runner_access_mode" => "all",
          "pack_access_mode" => "restricted"
        })

      refute revealed =~ "Choose at least one pack"

      render_change(lv, "scope_changed", %{
        "runner_access_mode" => "all",
        "pack_access_mode" => "restricted",
        "pack_scope" => ["pack:postgres"]
      })

      assert has_element?(lv, "#{form} input[value='pack:postgres']:checked")

      # Clearing a selection you had IS worth naming, at the control.
      cleared =
        render_change(lv, "scope_changed", %{
          "runner_access_mode" => "all",
          "pack_access_mode" => "restricted"
        })

      assert cleared =~ "Choose at least one pack"

      # Saving it anyway keeps the message at the control and the editor open,
      # rather than throwing it to the top of a page that scrolled away.
      saved =
        render_submit(lv, "save_scopes", %{
          "membership_id" => m.id,
          "runner_access_mode" => "all",
          "pack_access_mode" => "restricted"
        })

      assert saved =~ "Choose at least one pack"
      assert has_element?(lv, form)
    end

    test "the scope editor narrows the same grant to selected packs", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "PackScopeOrg"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "packscope-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: m}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "r1", group: "dba")

      # The picker offers the packs the SELECTED runners advertise, so the choices
      # come from the catalog rows, not from the account's pack versions.
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "postgres.uptime",
        pack_id: "postgres"
      )

      Fixtures.Catalog.create_action(runner: runner, action_id: "shell.run", pack_id: "shell")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      render_click(lv, "start_scope_edit", %{"membership_id" => m.id})

      # Choosing selected packs reveals the picker, offering exactly the
      # account's packs.
      render_change(
        element(lv, "form[phx-submit='save_scopes']"),
        %{
          "membership_id" => m.id,
          "runner_access_mode" => "all",
          "pack_access_mode" => "restricted"
        }
      )

      assert has_element?(lv, "form[phx-submit='save_scopes'] input[value='pack:postgres']")
      assert has_element?(lv, "form[phx-submit='save_scopes'] input[value='pack:shell']")

      render_submit(
        element(lv, "form[phx-submit='save_scopes']"),
        %{
          "membership_id" => m.id,
          "runner_access_mode" => "all",
          "pack_access_mode" => "restricted",
          "pack_scope" => ["pack:postgres"]
        }
      )

      assert Emisar.Accounts.runner_access_for_membership(account.id, m.id) ==
               %Emisar.Accounts.RunnerAccess{
                 mode: :all,
                 groups: [],
                 runner_ids: [],
                 pack_mode: :restricted,
                 pack_ids: ["postgres"]
               }

      # One labelled row per dimension: the unrestricted half states its mode,
      # the restricted half is named by its own pill, and neither says the word
      # its row label already carries.
      assert has_element?(lv, "dt", "runners:")
      assert has_element?(lv, "dt", "packs:")
      assert has_element?(lv, "span", "postgres")

      assert has_element?(
               lv,
               ~s|#member-access-#{m.id}[class~="grid-cols-[auto_minmax(0,1fr)]"]|
             )

      refute render(lv) =~ "selected packs"
    end

    test "picking a group disables its runners live, so they can't be double-scoped", %{
      conn: conn
    } do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg3"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "scoped3-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: m}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      _runner = Fixtures.Runners.create_runner(account_id: account.id, name: "r9", group: "dba")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      render_click(lv, "start_scope_edit", %{"membership_id" => m.id})

      # Selecting the group re-renders the picker with that group's runners disabled.
      html =
        render_change(
          element(lv, "form[phx-submit='save_scopes']"),
          %{
            "membership_id" => m.id,
            "runner_access_mode" => "restricted",
            "scope" => ["group:dba"]
          }
        )

      # That group's checkbox is now checked, and its runner is covered — tagged
      # "via group" and disabled (an individual tick would be redundant).
      assert html =~ ~r/checked[^>]*value="group:dba"/
      assert html =~ "via group"
    end

    test "clearing the last runner scope keeps it cleared", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg5"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      email = "scoped5-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: membership}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      _runner = Fixtures.Runners.create_runner(account_id: account.id, name: "r11", group: "dba")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      render_click(lv, "start_scope_edit", %{"membership_id" => membership.id})
      form = "form[phx-submit='save_scopes']"

      render_change(lv, "scope_changed", %{
        "runner_access_mode" => "restricted",
        "scope" => ["group:dba"]
      })

      assert has_element?(lv, "#{form} input[value='group:dba']:checked")

      html = render_change(lv, "scope_changed", %{"runner_access_mode" => "restricted"})

      refute has_element?(lv, "#{form} input[value='group:dba']:checked")
      assert html =~ "Choose at least one runner group or runner for selected access."
    end

    test "a runner past the first page can still be granted", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopePaged"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "scoped-paged-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: membership}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      # Well past the 20-row default page. The scope editor validates a selection
      # against the runner list the page loaded, so a paged load made this runner
      # ungrantable — the selection came back `:invalid_runner_access` and the
      # picker silently dropped it.
      runners =
        for n <- 1..36 do
          Fixtures.Runners.create_runner(
            account_id: account.id,
            name: "paged-#{String.pad_leading(Integer.to_string(n), 2, "0")}",
            group: "paged"
          )
        end

      last = List.last(runners)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      render_click(lv, "start_scope_edit", %{"membership_id" => membership.id})

      render_change(lv, "scope_changed", %{
        "runner_access_mode" => "restricted",
        "scope" => ["runner:#{last.id}"]
      })

      assert has_element?(
               lv,
               "form[phx-submit='save_scopes'] input[value='runner:#{last.id}']:checked"
             )
    end

    test "the scope picker pre-selects the member's existing scopes", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg2"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "scoped2-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: m}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      web = Fixtures.Runners.create_runner(account_id: account.id, name: "r9", group: "web")
      _dba = Fixtures.Runners.create_runner(account_id: account.id, name: "r8", group: "dba")

      # Pre-existing scope: one group + one runner from another group.
      {:ok, access} = Emisar.Accounts.RunnerAccess.restricted(["dba"], [web.id])
      Fixtures.Memberships.force_runner_access(m, access)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      html = render_click(lv, "start_scope_edit", %{"membership_id" => m.id})

      # One grouped picker (not two) that marks the stored group + runner checked.
      assert html =~ ~s(name="scope[]")
      assert html =~ ~r/checked[^>]*value="group:dba"/
      assert html =~ ~r/checked[^>]*value="runner:#{web.id}"/
    end

    test "a malformed scope submission is rejected without widening existing access", %{
      conn: conn
    } do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg4"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "scoped4-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: membership}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "r10", group: "web")

      {:ok, access} = Emisar.Accounts.RunnerAccess.restricted([], [runner.id])
      Fixtures.Memberships.force_runner_access(membership, access)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      html =
        render_submit(lv, "save_scopes", %{
          "membership_id" => membership.id,
          "runner_access_mode" => "restricted",
          "scope" => %{"crafted" => "all-runners"}
        })

      assert html =~ "Choose at least one runner group or runner for selected access."

      assert Emisar.Accounts.runner_access_for_membership(account.id, membership.id) == access
    end

    test "a scoped runner chip names the runner and carries its full id", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg5"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "scoped5-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: membership}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "r11", group: "web")

      {:ok, access} = Emisar.Accounts.RunnerAccess.restricted([], [runner.id])
      Fixtures.Memberships.force_runner_access(membership, access)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "span[title='#{runner.id}']", "r11")
    end

    test "a scoped runner that no longer resolves reads as a removed runner", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg6"}})
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "scoped6-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: membership}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "admin",
            runner_access_mode: "all"
          ),
          subject
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "r12", group: "web")

      {:ok, access} = Emisar.Accounts.RunnerAccess.restricted([], [runner.id])
      Fixtures.Memberships.force_runner_access(membership, access)

      # The scope outlives the runner row; the grant is still real, so the chip
      # says so honestly instead of printing an unreadable id prefix.
      {:ok, _deleted} = Emisar.Runners.delete_runner(runner, subject)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "span[title='#{runner.id}']", "Removed runner")
      refute html =~ "r12"
    end
  end

  describe "member administration" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "viewer"
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      %{owner: owner, account: account, member: member, membership: membership, lv: lv}
    end

    test "a pending invitation row shows its lifecycle and can resend the invite", %{
      owner: owner,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      email = "resend-web-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{membership: membership, invitation_token: old_token}} =
        Emisar.Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      {:ok, lv, html} =
        build_conn() |> log_in_user(owner) |> live(~p"/app/#{account}/settings/team")

      assert html =~ "Resend invite"

      assert has_element?(
               lv,
               "#member-metadata-#{membership.id} #member-invited-#{membership.id}"
             )

      assert has_element?(
               lv,
               "#member-metadata-#{membership.id} " <>
                 "#member-invitation-state-#{membership.id}.text-amber-300",
               "pending"
             )

      refute has_element?(lv, "#member-status-invitation-pending-#{membership.id}")
      refute has_element?(lv, "#member-statuses-#{membership.id}")
      refute has_element?(lv, "#member-status-unconfirmed-#{membership.id}")
      refute has_element?(lv, "#member-joined-#{membership.id}")
      refute html =~ "Invitation pending"
      refute html =~ "awaiting acceptance"

      invitation_metadata = lv |> element("#member-metadata-#{membership.id}") |> render()
      refute invitation_metadata =~ "never active"

      assert has_element?(
               lv,
               "button[phx-click='resend_invitation'][phx-value-membership_id='#{membership.id}']",
               "Resend invite"
             )

      assert has_element?(lv, "summary", "Actions")
      refute has_element?(lv, "button[phx-click='resend_invitation'] svg.emisar-icon")

      subscribe_team(account)
      html = render_click(lv, "resend_invitation", %{"membership_id" => membership.id})

      assert html =~ "Invitation resent to #{email}."
      assert Emisar.Accounts.fetch_invitation_by_token(old_token) == {:error, :not_found}
      assert_team_broadcast(lv, "membership.invitation_resent", membership.user_id)

      assert_email_sent(fn sent ->
        sent.to == [{"", email}] and
          sent.subject == "You're invited to #{account.name} on emisar" and
          sent.text_body =~ "/accept_invitation/"
      end)
    end

    test "the name editor tracks typing, so a roster re-render keeps the draft", %{
      lv: lv,
      membership: membership
    } do
      render_click(lv, "start_edit", %{"membership_id" => membership.id})

      render_change(lv, "validate_edit", %{"user" => %{"full_name" => "Half-typed Na"}})

      # Any team broadcast re-renders the roster from assigns; an untracked
      # edit form would snap the input back to the stored name.
      assert render(lv) =~
               ~r/<input(?=[^>]*\bname="user\[full_name\]")(?=[^>]*\bvalue="Half-typed Na")[^>]*>/
    end

    test "accepted member rows do not offer invite resend", %{lv: lv, membership: membership} do
      refute has_element?(
               lv,
               "button[phx-click='resend_invitation'][phx-value-membership_id='#{membership.id}']"
             )
    end

    test "an active member's row opens the labeled Actions menu with label-only rows", %{
      lv: lv,
      member: member
    } do
      assert has_element?(lv, "summary", "Actions")
      assert has_element?(lv, "details a[href*='actor_id=#{member.id}']", "View activity")
      refute has_element?(lv, "details a[href*='actor_id=#{member.id}'] svg.emisar-icon")
    end

    test "an admin manager gets the same labeled Actions menu", %{
      account: account,
      member: member
    } do
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(admin) |> live(~p"/app/#{account}/settings/team")

      assert has_element?(lv, "summary", "Actions")
      assert has_element?(lv, "details a[href*='actor_id=#{member.id}']", "View activity")
    end

    test "inviting a suppressed address warns on the success step, not a silent success", %{
      owner: owner,
      account: account
    } do
      # The address hard-bounced / was spam-flagged earlier, so the mailer skips
      # the send. The invite still exists, but the success step must say the email
      # won't arrive — otherwise the member sits "unconfirmed" forever. The
      # delivery workflow never returns the token, so the copy can't offer it.
      email = "bounced-#{System.unique_integer([:positive])}@example.com"
      {:ok, _} = Emisar.Mail.suppress(email, :hard_bounce)

      {:ok, lv, _html} =
        build_conn() |> log_in_user(owner) |> live(~p"/app/#{account}/settings/team/invite")

      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => email, "role" => "operator"}})
        |> render_submit()

      refute html =~ "Invitation sent"
      refute html =~ "We emailed a join link to"
      assert html =~ "Invitation saved, but we couldn&#39;t email it"
      assert html =~ "bounced or was marked spam"
      refute html =~ "another way"
      assert html =~ "Invite another"
      assert html =~ "View members"
    end

    test "a failed send says the invite is pending, not that it was sent", %{
      owner: owner,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})

      {:ok, lv, _html} =
        build_conn() |> log_in_user(owner) |> live(~p"/app/#{account}/settings/team/invite")

      html =
        lv
        |> form("#invite_form", %{
          "invite" => %{"email" => "undeliverable@example.com", "role" => "operator"}
        })
        |> render_submit()

      refute html =~ "Invitation sent"
      assert html =~ "Invitation saved, but the email didn&#39;t go out"
      assert html =~ "Resend it from the member list"
    end

    test "change_role promotes the member", %{
      account: account,
      lv: lv,
      membership: membership
    } do
      subscribe_team(account)

      html =
        render_click(lv, "change_role", %{"membership_id" => membership.id, "role" => "operator"})

      assert html =~ "Role updated."
      assert Emisar.Repo.reload!(membership).role == :operator
      assert_team_broadcast(lv, "membership.role_changed", membership.user_id)
    end

    test "promoting a member whose access is wider than yours names the remedy", %{
      account: account,
      membership: membership
    } do
      # The domain caps a promotion at the actor's own reach, so a scoped admin
      # can't manufacture a wider peer. That refusal has to reach the operator as
      # the fix — narrow them first — not as the generic "didn't apply".
      admin = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, db_access} = Emisar.Accounts.RunnerAccess.restricted(["db"], [])
      Fixtures.Memberships.force_runner_access(admin_membership, db_access)
      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())

      {:ok, lv, _html} =
        build_conn() |> log_in_user(admin) |> live(~p"/app/#{account}/settings/team")

      html =
        render_click(lv, "change_role", %{"membership_id" => membership.id, "role" => "operator"})

      assert html =~ "runner access is wider than yours"
      assert html =~ "Narrow their access first, then change their role."
      assert Emisar.Repo.reload!(membership).role == :viewer
    end

    test "the role dropdown offers every OTHER role and omits the current one", %{
      lv: lv,
      membership: membership
    } do
      # The member is seeded as a viewer; the role dropdown carries an item for
      # every role EXCEPT the current one, each OPENING a styled confirm modal —
      # so a `#change-role-<membership>-<role>` dialog renders per offered role.
      assert membership.role == :viewer

      for role <- ~w(operator admin owner) do
        assert has_element?(lv, "##{"change-role-#{membership.id}-#{role}"}")
      end

      # The current role is not offered as a change target — no dialog for it.
      refute has_element?(lv, "##{"change-role-#{membership.id}-viewer"}")
    end

    test "each role item confirms the privilege grant before changing", %{
      lv: lv,
      membership: membership
    } do
      # Every team action confirms through our own modal (never a native
      # data-confirm), so an admin can't fat-finger an escalation. The role item
      # opens the dialog; change_role fires only from its Confirm. The handler
      # still authorizes.
      assert has_element?(lv, "##{"change-role-#{membership.id}-operator"}")

      refute has_element?(
               lv,
               "[phx-value-membership_id='#{membership.id}'][data-confirm]"
             )
    end

    test "an unknown role value is rejected", %{lv: lv, membership: membership} do
      html =
        render_click(lv, "change_role", %{"membership_id" => membership.id, "role" => "root"})

      assert html =~ "Unknown role."
      assert Emisar.Repo.reload!(membership).role == :viewer
    end

    test "a suspended member's role stays editable — not locked beside a sync badge", %{
      account: account,
      lv: lv,
      membership: membership
    } do
      # Role editability tracks permission, not access-state: suspending a member
      # must NOT turn their role into a read-only chip (which, next to a synced
      # member's SCIM badge, misreads as "locked because synced"). It stays the
      # role picker — its confirm dialogs still render — and the change actually
      # applies (you set the role they'll have on reinstate).
      subscribe_team(account)

      render_click(lv, "suspend", %{"membership_id" => membership.id})

      assert has_element?(lv, "#member-suspended-#{membership.id}", "access suspended")

      assert_team_broadcast(lv, "membership.suspended", membership.user_id)

      assert has_element?(lv, "##{"change-role-#{membership.id}-operator"}")

      assert render_click(lv, "change_role", %{
               "membership_id" => membership.id,
               "role" => "operator"
             }) =~ "Role updated."

      assert Emisar.Repo.reload!(membership).role == :operator
      assert_team_broadcast(lv, "membership.role_changed", membership.user_id)
    end

    test "suspend then reinstate round-trips", %{
      account: account,
      lv: lv,
      membership: membership
    } do
      subscribe_team(account)

      assert render_click(lv, "suspend", %{"membership_id" => membership.id}) =~
               "Access suspended."

      assert Emisar.Repo.reload!(membership).disabled_at
      assert_team_broadcast(lv, "membership.suspended", membership.user_id)

      assert render_click(lv, "reinstate", %{"membership_id" => membership.id}) =~
               "Access restored."

      refute Emisar.Repo.reload!(membership).disabled_at
      assert_team_broadcast(lv, "membership.reinstated", membership.user_id)
    end

    test "account cautions use separate status lines and clear independently", %{
      account: account,
      lv: lv,
      member: member,
      owner: owner,
      membership: membership
    } do
      {:ok, _unconfirmed} =
        member
        |> Ecto.Changeset.change(confirmed_at: nil)
        |> Emisar.Repo.update()

      refute has_element?(lv, "#member-status-suspended-#{membership.id}")

      subscribe_team(account)
      render_click(lv, "suspend", %{"membership_id" => membership.id})

      assert has_element?(
               lv,
               "#member-status-suspended-#{membership.id} #member-suspended-#{membership.id}",
               "access suspended"
             )

      refute has_element?(
               lv,
               "#member-status-suspended-#{membership.id} > .bg-amber-400"
             )

      assert has_element?(
               lv,
               "#member-status-suspended-#{membership.id} #member-suspended-by-#{membership.id}",
               "by #{Emisar.Accounts.user_display_name(owner)}"
             )

      assert has_element?(
               lv,
               "#member-status-unconfirmed-#{membership.id} #member-unconfirmed-#{membership.id}",
               "Email unconfirmed"
             )

      assert has_element?(
               lv,
               "#member-status-unconfirmed-#{membership.id} > .bg-amber-400"
             )

      assert_team_broadcast(lv, "membership.suspended", membership.user_id)

      render_click(lv, "reinstate", %{"membership_id" => membership.id})
      refute has_element?(lv, "#member-status-suspended-#{membership.id}")
      refute has_element?(lv, "#member-suspended-by-#{membership.id}")
      assert has_element?(lv, "#member-unconfirmed-#{membership.id}", "Email unconfirmed")

      assert has_element?(
               lv,
               "#member-status-unconfirmed-#{membership.id} > .bg-amber-400"
             )

      assert_team_broadcast(lv, "membership.reinstated", membership.user_id)
    end

    test "an ordinary roster reader sees the hold but not its author", %{
      account: account,
      owner: owner,
      membership: membership
    } do
      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      assert {:ok, _suspended} = Emisar.Accounts.suspend_membership(membership, owner_subject)

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/settings/team")

      assert has_element?(lv, "#member-suspended-#{membership.id}", "access suspended")
      refute has_element?(lv, "#member-suspended-by-#{membership.id}")
    end

    test "remove soft-deletes the membership through the typed-confirm dialog", %{
      account: account,
      lv: lv,
      member: member,
      membership: membership
    } do
      # Drive the dialog: type the member's email, then Confirm.
      dialog = "remove-member-#{membership.id}"
      type_confirm_token(lv, dialog, member.email)
      subscribe_team(account)
      assert confirm_dialog(lv, dialog, "Remove member") =~ "Member removed."
      assert Emisar.Repo.reload!(membership).deleted_at
      assert_team_broadcast(lv, "membership.removed", membership.user_id)
    end

    test "the remove dialog spells out that removal is permanent", %{lv: lv} do
      # Heavier than the reversible suspend/reset confirms — it states what's lost.
      assert render(lv) =~ "they lose access immediately"
      assert render(lv) =~ "need a fresh invite to return"
    end

    test "remove's typed-confirm: Confirm won't fire until the email matches", %{
      lv: lv,
      membership: membership
    } do
      dialog = "remove-member-#{membership.id}"

      # Empty + wrong token → Confirm disabled, `remove` never dispatched.
      assert_raise ArgumentError, ~r/disabled/, fn ->
        confirm_dialog(lv, dialog, "Remove member")
      end

      type_confirm_token(lv, dialog, "wrong@example.com")

      assert_raise ArgumentError, ~r/disabled/, fn ->
        confirm_dialog(lv, dialog, "Remove member")
      end

      # The membership is untouched — no bypassing event fired.
      refute Emisar.Repo.reload!(membership).deleted_at
    end

    test "end_sessions kills the member's signed-in devices", %{
      lv: lv,
      member: member,
      membership: membership
    } do
      _member_conn = build_conn() |> log_in_user(member)

      assert render_click(lv, "end_sessions", %{"membership_id" => membership.id}) =~
               "All sessions ended for that user."
    end
  end

  describe "a directory-synced member's role is IdP-managed" do
    setup %{conn: conn} do
      # SSO/SCIM is enterprise-gated, so a synced member only exists on an enterprise
      # account — and the team page loads identities only when SSO is available.
      {conn, owner, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, owner: owner, account: account}
    end

    test "the roster shows it read-only and refuses a crafted change_role", %{
      conn: conn,
      account: account
    } do
      # A member provisioned through a SCIM (directory-sync) provider has an IdP-owned
      # role — recomputed on every sync — so a manual change silently reverts. The
      # roster must NOT offer a change_role control, and a crafted change_role event is
      # refused (not just hidden), leaving the role untouched.
      synced = scim_synced_member(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(
               lv,
               "a[title='Provisioned via SCIM — Acme Okta']",
               "Acme Okta"
             )

      refute render(lv) =~ "SCIM · Acme Okta"

      refute has_element?(
               lv,
               "button[phx-click='change_role'][phx-value-membership_id='#{synced.membership.id}']"
             )

      # ...and it reads as provider-managed, via a hover tooltip explaining the lock.
      assert has_element?(lv, "[role='tooltip']", "managed by")

      refute has_element?(
               lv,
               "[phx-click='start_scope_edit'][phx-value-membership_id='#{synced.membership.id}']"
             )

      html =
        render_click(lv, "change_role", %{
          "membership_id" => synced.membership.id,
          "role" => "admin"
        })

      assert html =~ "set by their identity provider"
      assert Emisar.Repo.reload!(synced.membership).role == :operator

      access_before =
        Emisar.Accounts.runner_access_for_membership(account.id, synced.membership.id)

      scope_html =
        render_click(lv, "start_scope_edit", %{"membership_id" => synced.membership.id})

      assert scope_html =~ "runner access is set by their identity provider"

      assert Emisar.Accounts.runner_access_for_membership(account.id, synced.membership.id) ==
               access_before
    end

    test "the roster hides Edit name and refuses a crafted save_edit", %{
      conn: conn,
      account: account
    } do
      # A synced member's profile is the directory's — the IdP re-pushes the name,
      # so a local edit silently reverts. The roster hides the affordance and the
      # domain refuses a crafted save (IL-15), leaving the name untouched.
      synced = scim_synced_member(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      refute has_element?(
               lv,
               "[phx-click='start_edit'][phx-value-membership_id='#{synced.membership.id}']"
             )

      html =
        render_click(lv, "save_edit", %{
          "membership_id" => synced.membership.id,
          "user" => %{"full_name" => "Hijacked"}
        })

      assert html =~ "managed by your identity provider"
      assert Emisar.Repo.reload!(synced.user).full_name == "Synced Member"
    end

    test "a member deactivated in the IdP can't be reinstated (stays suspended)", %{
      conn: conn,
      account: account
    } do
      # Deactivating in the directory (SCIM active:false) suspends the member; reinstating
      # them in emisar would grant access the IdP revoked, so a crafted reinstate is
      # refused and they stay suspended — reactivation is the IdP's to make.
      synced = scim_synced_member(account)

      {:ok, _} =
        Emisar.SSO.scim_update_user(
          synced.provider,
          synced.resource_id,
          %Emisar.SSO.SCIMUserUpdate{active: false}
        )

      assert Emisar.Repo.reload!(synced.membership).disabled_at

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      html = render_click(lv, "reinstate", %{"membership_id" => synced.membership.id})

      assert html =~ "deactivated in your identity provider"
      assert Emisar.Repo.reload!(synced.membership).disabled_at
    end
  end

  describe "invite form live validation (phx-change)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")
      %{conn: conn, account: account, lv: lv}
    end

    test "a blank email surfaces an inline error via phx-change, not a flash", %{lv: lv} do
      # The live-validation path (phx-change="validate") shows the field error as
      # the operator types/clears — before they ever submit. `_target` is how a
      # browser says which field that was; without it this reads as an untouched
      # field, which stays quiet by design.
      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => "", "role" => "operator"}})
        |> render_change(%{"_target" => ["invite", "email"]})

      assert html =~ "can&#39;t be blank"
      refute html =~ "Could not send invitation"
    end

    test "a malformed email surfaces inline via phx-change", %{lv: lv} do
      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => "b ob@x.com", "role" => "operator"}})
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end

    test "a role outside the allowed set is rejected with no membership created", %{lv: lv} do
      email = "rolecheck-#{System.unique_integer([:positive])}@example.com"

      # The role radios only offer valid roles, so push the event directly to
      # forge an out-of-set role. validate_inclusion fails, the invite never
      # reaches the context, and the form re-renders instead of the success step.
      html =
        render_submit(lv, "invite", %{"invite" => %{"email" => email, "role" => "superadmin"}})

      assert html =~ "Send invite"
      refute html =~ "Invitation sent"
      assert Emisar.Users.fetch_user_by_email(email) == {:error, :not_found}
    end
  end

  describe "reset a member's 2FA" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      %{conn: conn, owner: owner, account: account, member: member, membership: membership}
    end

    test "the Reset 2FA action is offered only when the member is enrolled", %{
      conn: conn,
      account: account,
      member: member,
      membership: membership
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      path = ~p"/app/#{account}/settings/team/#{membership.id}/reset_2fa"
      refute has_element?(lv, ~s|a[href="#{path}"]|, "Reset 2FA")

      enroll_mfa(member)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, ~s|a[href="#{path}"]|, "Reset 2FA")

      invited = Fixtures.Users.create_user() |> enroll_mfa()

      pending =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: invited.id,
          invitation_token_digest: "pending-reset-invite"
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      pending_path = ~p"/app/#{account}/settings/team/#{pending.id}/reset_2fa"
      refute has_element?(lv, ~s|a[href="#{pending_path}"]|, "Reset 2FA")
    end

    test "an owner must prove their own current TOTP before the member is reset", %{
      conn: conn,
      owner: owner,
      account: account,
      member: member,
      membership: membership
    } do
      secret = Emisar.Auth.generate_mfa_secret()
      session_token = get_session(conn, :user_token)

      Fixtures.Users.enable_mfa!(
        secret,
        Fixtures.Subjects.subject_for(owner, account),
        session_token: session_token
      )

      enroll_mfa(member)

      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/settings/team/#{membership.id}/reset_2fa")

      assert html =~ "This removes their current factor"

      render_hook(lv, "verify_reset_totp", %{
        "otp" => NimbleTOTP.verification_code(secret)
      })

      assert_redirect(lv, ~p"/app/#{account}/settings/team")

      reloaded = Emisar.Repo.reload!(member)
      assert is_nil(reloaded.mfa_enabled_at)
    end

    test "an owner can use one of their recovery codes for the reset", %{
      conn: conn,
      owner: owner,
      account: account,
      member: member,
      membership: membership
    } do
      session_token = get_session(conn, :user_token)

      {_owner, [recovery_code | _]} =
        Fixtures.Users.enable_mfa!(
          Emisar.Auth.generate_mfa_secret(),
          Fixtures.Subjects.subject_for(owner, account),
          session_token: session_token
        )

      enroll_mfa(member)

      {:ok, lv, _html} =
        live(conn, ~p"/app/#{account}/settings/team/#{membership.id}/reset_2fa")

      render_click(lv, "use_reset_recovery")

      lv
      |> form("#member-mfa-reset-recovery", %{"recovery" => %{"code" => recovery_code}})
      |> render_submit()

      assert_redirect(lv, ~p"/app/#{account}/settings/team")
      assert is_nil(Emisar.Repo.reload!(member).mfa_enabled_at)
    end

    test "a stolen session without a current factor cannot submit a reset", %{
      conn: conn,
      account: account,
      member: member,
      membership: membership
    } do
      enroll_mfa(member)

      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/settings/team/#{membership.id}/reset_2fa")

      assert html =~ "A second factor is required"
      refute has_element?(lv, "#member-mfa-reset-totp")
      refute has_element?(lv, "#member-mfa-reset-recovery")
      refute is_nil(Emisar.Repo.reload!(member).mfa_enabled_at)
    end

    test "an MFA-satisfying SSO session gets a CSRF-protected reauthentication action", %{
      conn: conn,
      owner: owner,
      account: account,
      member: member,
      membership: membership
    } do
      provider =
        Fixtures.SSO.create_identity_provider(%{
          account_id: account.id,
          name: "Acme SSO",
          satisfies_mfa: true
        })

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: owner.id,
          provider_identifier: "team-reset-owner"
        })

      session =
        Fixtures.Auth.create_session_token!(owner, :sso, DateTime.utc_now(), %{},
          user_identity_id: identity.id
        )

      enroll_mfa(member)
      conn = put_session(conn, :user_token, session)

      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/settings/team/#{membership.id}/reset_2fa")

      path = ~p"/app/#{account}/settings/team/#{membership.id}/reset_2fa/sso"
      assert html =~ "Reauthenticate with your identity provider"
      assert html =~ "Verify with Acme SSO"
      refute has_element?(lv, "#member-mfa-reset-totp")
      refute has_element?(lv, "#member-mfa-reset-recovery")
      assert has_element?(lv, ~s|a[href="#{path}"][data-method="post"][data-csrf]|)
    end

    test "a wrong code stays on the focused challenge and leaves the member enrolled", %{
      conn: conn,
      owner: owner,
      account: account,
      member: member,
      membership: membership
    } do
      secret = Emisar.Auth.generate_mfa_secret()
      session_token = get_session(conn, :user_token)

      Fixtures.Users.enable_mfa!(
        secret,
        Fixtures.Subjects.subject_for(owner, account),
        session_token: session_token
      )

      enroll_mfa(member)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team/#{membership.id}/reset_2fa")

      wrong_code =
        secret
        |> NimbleTOTP.verification_code()
        |> String.to_integer()
        |> Kernel.+(1)
        |> rem(1_000_000)
        |> Integer.to_string()
        |> String.pad_leading(6, "0")

      html = render_hook(lv, "verify_reset_totp", %{"otp" => wrong_code})

      assert html =~ "That authenticator code didn"
      refute is_nil(Emisar.Repo.reload!(member).mfa_enabled_at)
    end
  end

  describe "account-wide MFA toggle" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      %{conn: conn, owner: owner, account: account}
    end

    test "an owner without MFA hits the lockout guard", %{conn: conn, account: account} do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "button[disabled]", "Enforce 2FA")
      assert html =~ "state.locked"
      assert html =~ "lock yourself out"

      html = render_click(lv, "toggle_require_mfa", %{})

      assert html =~ "Enable 2FA on your own profile first"
    end

    test "an owner with MFA enforces it account-wide", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Emisar.Auth.generate_mfa_secret()
      session_token = get_session(conn, :user_token)

      {_user, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner, account),
          session_token: session_token
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      refute has_element?(lv, "button[disabled]", "Enforce 2FA")
      assert render_click(lv, "toggle_require_mfa", %{}) =~ "Account-wide MFA enforced."
      assert Emisar.Repo.reload!(account).settings.require_mfa
    end

    test "an operator is refused at the event level (IL-15 — owners + admins only)", %{
      account: account
    } do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/settings/team")

      html = render_click(lv, "toggle_require_mfa", %{})

      assert html =~ "Only owners and admins can change this setting."
      refute Emisar.Repo.reload!(account).settings.require_mfa
    end

    test "enforcing 2FA is a confirm-modal button (our modal) that fires the handler",
         %{conn: conn, owner: owner, account: account} do
      Fixtures.Users.enable_mfa!(
        Emisar.Auth.generate_mfa_secret(),
        Fixtures.Subjects.subject_for(owner, account),
        session_token: get_session(conn, :user_token)
      )

      # Off: the trigger reads "Enforce 2FA" and opens our confirm dialog.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Enforce 2FA"
      assert has_element?(lv, "#enforce-mfa")

      # Confirming fires the (server-authz-gated) handler.
      assert render_click(lv, "toggle_require_mfa", %{}) =~ "Account-wide MFA enforced."
      assert Emisar.Repo.reload!(account).settings.require_mfa

      # On: the trigger flips to the turn-off action.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Stop enforcing 2FA"
    end
  end

  describe "monthly-report toggle" do
    setup %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "an owner turns the report off and back on", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      refute has_element?(lv, "h4 + span")
      assert has_element?(lv, ~s(button[role="switch"]), "Turn off")

      assert render_click(lv, "toggle_monthly_report", %{}) =~ "Monthly report turned off."
      assert Emisar.Repo.reload!(account).settings.monthly_report_opt_out
      assert has_element?(lv, ~s(button[role="switch"]), "Turn back on")

      assert render_click(lv, "toggle_monthly_report", %{}) =~ "Monthly report turned back on"
      refute Emisar.Repo.reload!(account).settings.monthly_report_opt_out
    end

    test "an operator is refused at the event level (IL-15 — owners + admins only)", %{
      account: account
    } do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/settings/team")

      html = render_click(lv, "toggle_monthly_report", %{})

      assert html =~ "Only owners and admins can change this setting."
      refute Emisar.Repo.reload!(account).settings.monthly_report_opt_out
    end
  end

  describe "2FA enrollment stat" do
    test "keeps the zero count neutral while the status dot carries attention", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "#mfa-enrolled-count.text-zinc-200", "0")
      refute has_element?(lv, "#mfa-enrolled-count.text-amber-300")
    end

    test "renders account-wide enrollment, not just the visible page", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)

      member = Fixtures.Users.create_user()
      member |> Ecto.Changeset.change(mfa_enabled_at: DateTime.utc_now()) |> Emisar.Repo.update()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "admin"
      )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      # Owner (unenrolled) + the enrolled member → 1 of 2. The counts come from
      # Accounts.team_mfa_stats (account-wide), not @memberships.
      assert html =~ "2FA enrolled:"
      assert html =~ "1 of 2"
    end
  end

  describe "deliverability (email suppression) badge" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "flags a member whose email is on the suppression list", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, _} = Emisar.Mail.suppress(user.email, :hard_bounce, "bounce")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "Email bouncing"
      assert html =~ "Contact support to clear it"
    end

    test "shows no badge when no member email is suppressed", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      refute html =~ "Email bouncing"
    end
  end

  describe "member-row timestamps render through <.local_time>" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "the joined + activity times are hook-driven, with the prefix space kept", %{
      conn: conn,
      account: account
    } do
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )
        |> Fixtures.Memberships.set_last_active_at(DateTime.utc_now())

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      # Both relative times render as the viewer-local <time> (consistent with
      # the rest of the app), not a static server string.
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-format="relative")
      # Mid-sentence spacing survives the formatter's line-break (the {" "}
      # guard): "joined <time>" and "last active <time>", never abutting.
      assert html =~ ~r/joined\s<time/
      refute html =~ ~r/joined<time/
      assert html =~ ~r/last active\s<time[^>]+id="active-#{membership.id}"/
      refute html =~ ~r/last active<time/
    end

    test "falls back to the global sign-in until membership activity is recorded", %{
      conn: conn,
      account: account
    } do
      member =
        Fixtures.Users.create_user() |> Fixtures.Users.set_last_sign_in_at(DateTime.utc_now())

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ ~r/last active\s<time[^>]+id="active-#{membership.id}"/
    end

    test "a member with no activity evidence shows the static 'never active'", %{
      conn: conn,
      account: account
    } do
      member = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "never active"
    end

    test "an email-fallback identity is not duplicated or followed by a leading separator", %{
      conn: conn,
      account: account
    } do
      member = Fixtures.Users.create_user(%{full_name: nil})

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(lv, "#member-name-#{membership.id}", member.email)

      metadata_html =
        lv
        |> element("#member-metadata-#{membership.id}")
        |> render()

      assert metadata_html =~ ~r/metadata-[^"]+"[^>]*>\s*<span[^>]*>\s*joined\s<time/
      refute metadata_html =~ member.email
      refute metadata_html =~ ~r/metadata-[^"]+"[^>]*>\s*(<span[^>]*>)?\s*·/
    end
  end

  describe "real-time roster updates (PubSub)" do
    test "an unrelated handle_info message is ignored, not crashed", %{conn: conn} do
      # The badge/fleet on_mount hooks forward account-topic broadcasts to every
      # LV, so TeamLive must carry the mandatory handle_info(_, socket) catch-all
      # (a missing one crashes the socket on the first stray message).
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      send(lv.pid, {:some_unrelated_event, :payload})

      # The process survived and still renders — render/1 raises if the socket died.
      assert render(lv) =~ "Two-factor"
    end

    test "the disconnected (dead) render shows the loading state, never the roster", %{conn: conn} do
      # handle_params gates the roster reads (and mount the subscribe) behind
      # connected?/1 (IL-18) — so the dead render a plain GET produces must show
      # <.loading_state>, with no member rows read or rendered. A teammate is
      # seeded precisely so "no roster on the dead render" is meaningful.
      {conn, _user, account} = register_and_log_in(conn, %{account: %{name: "DeadRenderOrg"}})

      teammate = Fixtures.Users.create_user(%{full_name: "Deadrender Teammate"})

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: teammate.id,
          role: "operator"
        )

      dead = conn |> get(~p"/app/#{account}/settings/team") |> html_response(200)

      assert dead =~ "Loading…"
      refute dead =~ "Deadrender Teammate"
    end
  end

  describe "pagination / filter param recovery" do
    test "a hand-edited bad cursor param recovers via the single clean retry", %{conn: conn} do
      # A garbage `after` cursor makes the keyset read return
      # {:error, :invalid_cursor}; load/2 retries once with %{} (since the params
      # were non-empty), so the page recovers and renders the roster instead of
      # 500-ing or landing on the load-error empty state.
      {conn, _user, account} = register_and_log_in(conn, %{account: %{name: "RecoverOrg"}})

      teammate = Fixtures.Users.create_user(%{full_name: "Recover Teammate"})

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: teammate.id,
          role: "operator"
        )

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/settings/team?after=not-a-real-cursor%21%21")

      # Recovered: the roster rendered (the retry's clean read), and it's NOT the
      # load-error state.
      assert html =~ "Recover Teammate"
      refute html =~ "Couldn't load your team"
    end
  end

  describe "client validation is not the authorization gate (IL-15)" do
    test "a viewer's well-formed invite is still refused server-side", %{conn: conn} do
      # The invite changeset is purely UX — a viewer can pass every field-level
      # check (valid email, valid role) and the `invite` handler must STILL deny
      # them via can_manage?, never creating a membership.
      {_owner_conn, _owner, account} = register_and_log_in(conn, %{account: %{name: "ValOrg"}})

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/settings/team")

      email = "valid-but-denied-#{System.unique_integer([:positive])}@example.com"

      html = render_submit(lv, "invite", %{"invite" => %{"email" => email, "role" => "operator"}})

      # The denial is the membership-management flash, and no user/membership was
      # created from the forged event.
      assert html =~ "Only owners and admins can invite members."
      assert Emisar.Users.fetch_user_by_email(email) == {:error, :not_found}
    end
  end

  describe "a member that vanished mid-flight is a graceful no-op" do
    setup %{conn: conn} do
      # An owner whose roster does NOT contain `ghost_id` — so find_membership
      # returns nil for it and each handler short-circuits without touching the DB.
      {conn, _owner, account} = register_and_log_in(conn, %{account: %{name: "GhostOrg"}})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      %{lv: lv, ghost_id: Ecto.UUID.generate()}
    end

    test "change_role on an unknown membership id is ignored", %{lv: lv, ghost_id: ghost_id} do
      # change_role finds no row → the `nil` clause returns the socket unchanged
      # (no flash, no write).
      html = render_click(lv, "change_role", %{"membership_id" => ghost_id, "role" => "admin"})
      refute html =~ "Role updated."
      refute html =~ "Unknown role."
    end

    test "remove / save_edit / save_scopes on an unknown id are silent no-ops", %{
      lv: lv,
      ghost_id: ghost_id
    } do
      # All three route through with_membership, whose nil branch returns the
      # socket untouched — no success flash, no error flash, no crash.
      remove_html = render_click(lv, "remove", %{"membership_id" => ghost_id})
      refute remove_html =~ "Member removed."

      edit_html =
        render_submit(lv, "save_edit", %{
          "membership_id" => ghost_id,
          "user" => %{"full_name" => "Nobody"}
        })

      refute edit_html =~ "Member updated."

      scopes_html =
        render_submit(lv, "save_scopes", %{
          "membership_id" => ghost_id,
          "scope" => []
        })

      refute scopes_html =~ "Scope updated."
    end
  end

  defp enroll_mfa(user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: ["digest-a", "digest-b"]
      )
      |> Emisar.Repo.update()

    user
  end

  # Provision a member through a directory-sync (SCIM) provider so their role is the
  # IdP's. Direct-build the provider with scim_enabled (trusted test data, as the
  # seed does); scim_provision_user creates the user + identity + membership at the
  # provider's default_role.
  defp scim_synced_member(account) do
    {:ok, provider} =
      %Emisar.SSO.IdentityProvider{}
      |> Ecto.Changeset.change(%{
        account_id: account.id,
        kind: :okta,
        name: "Acme Okta",
        issuer: "https://idp.test",
        client_id: "cid",
        client_secret: "secret",
        identifier_claim: :sub,
        default_role: :operator,
        provisioner: :jit,
        enabled: true,
        scim_enabled: true
      })
      |> Emisar.Repo.insert()

    external_id = "ext-#{System.unique_integer([:positive])}"

    {:ok, %{identity: identity, user: user}} =
      Emisar.SSO.scim_provision_user(provider, %{
        external_id: external_id,
        email: "synced-#{System.unique_integer([:positive])}@example.test",
        full_name: "Synced Member"
      })

    # A sync recompute marks the role directory-managed — the domain-owned lock
    # signal `update_membership_role` refuses on. A real synced member has been
    # through this; without it the row isn't actually directory-managed.
    {:ok, membership} = Emisar.SSO.recompute_role_for_identity(provider, identity)

    %{provider: provider, membership: membership, resource_id: identity.id, user: user}
  end
end
