defmodule EmisarWeb.TeamLiveTest do
  @moduledoc """
  Regression test for #112: TeamLive showed "Only owners and admins can
  invite" to a user whose role WAS owner because `can_manage?(assigns)`
  was being called with the bare assigns map instead of a socket-shaped
  struct and the pattern match failed.
  """

  use EmisarWeb.ConnCase, async: true

  describe "GET /app/settings/team as an owner" do
    test "renders the invite form (not the read-only banner)", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "Invite a member"
      assert html =~ "Send invite"
      refute html =~ "Only owners and admins can invite"
      # Each assignable role is explained, not just named — assigning one is a
      # privilege grant.
      assert html =~ "Read-only access to runs"
      assert html =~ "Dispatch runs and approve actions"
    end
  end

  describe "invite form validation" do
    test "an invalid email renders inline on the field, not in a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => "not-an-email", "role" => "operator"}})
        |> render_submit()

      # Inline field error (rendered by <.input>/<.error> under the input)…
      assert html =~ "must have the @ sign and no spaces"
      # …and no flash banner — the bad address never reaches the mailer.
      refute html =~ "Could not send invitation"
      refute html =~ "Invited not-an-email"
    end
  end

  describe "resend confirmation (self)" do
    test "an unconfirmed user can resend their own confirmation email", %{conn: conn} do
      # closes TEAM-015-T03
      # TeamLive defines no `resend_confirmation` handler — the row's button is
      # served by the portal-wide `:email_confirmation` on_mount hook (the same
      # one behind the verify-email banner), which owns the send + rate-limit. A
      # successful click flashing the hook's copy proves the global handler, not
      # TeamLive, fielded the event.
      {conn, user, account} = register_and_log_in(conn)
      # Simulate the signed-up-but-unconfirmed state (register_and_log_in
      # confirms by default).
      {:ok, _} = user |> Ecto.Changeset.change(confirmed_at: nil) |> Emisar.Repo.update()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ "Resend confirmation"

      html = lv |> element("button", "Resend confirmation") |> render_click()
      assert html =~ "Confirmation email sent"
    end

    test "a confirmed user sees no resend button", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      refute html =~ "Resend confirmation"
    end
  end

  describe "GET /app/settings/team as a viewer" do
    test "renders the read-only banner instead of the form", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{name: "ViewerOrg"}})

      {:ok, m} = Emisar.Accounts.fetch_membership_for_session(user, nil)
      _ = Emisar.Fixtures.force_membership_role(m, "viewer")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "Only owners and admins can invite"
      refute html =~ "Send invite"
    end
  end

  describe "a non-manager (operator / viewer) sees the roster read-only" do
    setup %{conn: conn} do
      # An owner with the account + a teammate to render in the roster, then a
      # second member we log in AS to observe the read-only view.
      {_owner_conn, _owner, account} =
        register_and_log_in(conn, %{account: %{name: "ReadOnlyOrg"}})

      teammate = Emisar.Fixtures.user_fixture(%{full_name: "Teammate Tess"})

      teammate_membership =
        Emisar.Fixtures.membership_fixture(
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
        # closes TEAM-001-T02
        member = Emisar.Fixtures.user_fixture()

        _ =
          Emisar.Fixtures.membership_fixture(
            account_id: account.id,
            user_id: member.id,
            role: unquote(role)
          )

        {:ok, lv, html} =
          build_conn() |> log_in_user(member) |> live(~p"/app/#{account}/settings/team")

        # The roster IS visible — they can audit teammates even read-only.
        assert html =~ "Teammate Tess"
        assert html =~ teammate.email

        # …but no management surface: no invite, no Actions menu, no role
        # dropdown, no per-row management events on the teammate's row.
        refute html =~ "Invite member"
        refute html =~ "Send invite"
        refute has_element?(lv, "summary", "Actions")

        refute has_element?(
                 lv,
                 "button[phx-click='change_role'][phx-value-membership_id='#{teammate_membership.id}']"
               )

        # The read-only footer names their role and points them at who can manage.
        assert html =~ "Only owners and admins can invite or manage members."
        assert html =~ "Your role: #{unquote(role)}"

        # Auditing a teammate stays available — the "View activity" affordance.
        assert html =~ "View activity"
      end
    end
  end

  describe "a non-manager's crafted management events are denied (IL-15)" do
    setup %{conn: conn} do
      # An owner account; a viewer we log in AS; a teammate to target.
      {_owner_conn, _owner, account} =
        register_and_log_in(conn, %{account: %{name: "CraftedOrg"}})

      viewer = Emisar.Fixtures.user_fixture()

      Emisar.Fixtures.membership_fixture(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      target = Emisar.Fixtures.user_fixture()

      target_membership =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/settings/team")

      %{lv: lv, account: account, target: target, target_membership: target_membership}
    end

    test "change_role is refused and the role is untouched", %{
      lv: lv,
      target_membership: target_membership
    } do
      # closes TEAM-004-T08
      html =
        render_click(lv, "change_role", %{
          "membership_id" => target_membership.id,
          "role" => "admin"
        })

      assert html =~ "Only owners and admins can manage memberships."
      assert Emisar.Repo.reload!(target_membership).role == :operator
    end

    test "remove is refused and the membership survives", %{
      lv: lv,
      target_membership: target_membership
    } do
      # closes TEAM-005-T06
      html = render_click(lv, "remove", %{"membership_id" => target_membership.id})

      assert html =~ "Only owners and admins can manage memberships."
      refute Emisar.Repo.reload!(target_membership).deleted_at
    end

    test "suspend is refused and the member stays active", %{
      lv: lv,
      target_membership: target_membership
    } do
      # closes TEAM-006-T07
      html = render_click(lv, "suspend", %{"membership_id" => target_membership.id})

      assert html =~ "Only owners and admins can manage memberships."
      refute Emisar.Repo.reload!(target_membership).disabled_at
    end

    test "save_edit (admin name change) is refused and the name is untouched", %{
      lv: lv,
      target: target,
      target_membership: target_membership
    } do
      # closes TEAM-007-T05
      # The edit form is never in a viewer's DOM (no Actions menu), so push the
      # event directly — the server gate must still refuse it.
      html =
        render_submit(lv, "save_edit", %{
          "membership_id" => target_membership.id,
          "user" => %{"full_name" => "Hijacked Name"}
        })

      assert html =~ "Only owners and admins can manage memberships."
      assert Emisar.Repo.reload!(target).full_name == target.full_name
    end

    test "end_sessions is refused", %{lv: lv, target_membership: target_membership} do
      # closes TEAM-010-T04
      html = render_click(lv, "end_sessions", %{"membership_id" => target_membership.id})

      assert html =~ "Only owners and admins can manage memberships."
    end

    test "reset_mfa is refused server-side even if the event is forged", %{
      lv: lv,
      target: target,
      target_membership: target_membership
    } do
      # closes TEAM-009-T03 TEAM-009-T07
      # Enroll the target so the context's mutation path is the thing being
      # blocked, not a "not enrolled" no-op.
      enroll_mfa(target)

      html = render_click(lv, "reset_mfa", %{"membership_id" => target_membership.id})

      # reset_mfa is wrapped in Permissions.gated, so the denial is the generic
      # gated flash (apostrophe HTML-escaped); the member's MFA is untouched.
      assert html =~ "You don&#39;t have permission to do that."
      assert Emisar.Repo.reload!(target).mfa_enabled_at
    end

    test "save_scopes is refused via the Runners gate, scopes unchanged", %{
      lv: lv,
      target_membership: target_membership
    } do
      # closes TEAM-011-T04
      html =
        render_submit(lv, "save_scopes", %{
          "membership_id" => target_membership.id,
          "groups" => ["dba"],
          "runners" => []
        })

      # The Runners context denies with :unauthorized; the LV maps it to the same
      # membership-management flash, and no scope rows were written.
      assert html =~ "Only owners and admins can manage memberships."
      assert Emisar.Runners.runner_scopes_for_membership(target_membership.id) == []
    end
  end

  describe "runner-scope editor (#238)" do
    test "owner can save a group + runner scope for an invited admin", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg"}})

      # An invited admin we'll scope.
      email = "scoped-#{System.unique_integer([:positive])}@example.com"

      subject = Emisar.Fixtures.subject_for(owner, account, role: :owner)

      {:ok, %{membership: m}} =
        Emisar.Accounts.invite_user_to_account(email, "admin", subject)

      # A runner the scope can target.
      {:ok, runner} =
        Emisar.Runners.create_runner(%{"name" => "r1", "group" => "dba"}, subject)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      # Default state — no scopes = "all runners" label rendered.
      assert html =~ "access: all runners"

      # Open the inline editor for the invited admin.
      render_click(lv, "start_scope_edit", %{"membership_id" => m.id})

      # Submit a scope with one group + one runner.
      render_submit(
        element(lv, "form[phx-submit='save_scopes']"),
        %{
          "membership_id" => m.id,
          "groups" => ["dba"],
          "runners" => [runner.id]
        }
      )

      # Persisted as two scope rows.
      scopes = Emisar.Runners.runner_scopes_for_membership(m.id)
      assert Enum.any?(scopes, &(&1.scope_type == :group and &1.scope_value == "dba"))
      assert Enum.any?(scopes, &(&1.scope_type == :runner and &1.scope_value == runner.id))
    end

    test "the scope multi-selects pre-select the member's existing scopes", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg2"}})
      subject = Emisar.Fixtures.subject_for(owner, account, role: :owner)

      email = "scoped2-#{System.unique_integer([:positive])}@example.com"
      {:ok, %{membership: m}} = Emisar.Accounts.invite_user_to_account(email, "admin", subject)
      {:ok, runner} = Emisar.Runners.create_runner(%{"name" => "r9", "group" => "dba"}, subject)

      # Pre-existing scope: one group + one runner.
      {:ok, :ok} =
        Emisar.Runners.replace_runner_scopes(
          m,
          [{"group", "dba"}, {"runner", runner.id}],
          subject
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      html = render_click(lv, "start_scope_edit", %{"membership_id" => m.id})

      # Both multi-selects mark the stored scope's option selected, so the
      # editor opens reflecting current state (selection round-trips through
      # the shared <.select>).
      assert html =~ ~s(name="groups[]")
      assert html =~ ~s(name="runners[]")
      assert html =~ ~r/<option(?=[^>]*\bvalue="dba")(?=[^>]*\bselected)[^>]*>/
      assert html =~ ~r/<option(?=[^>]*\bvalue="#{runner.id}")(?=[^>]*\bselected)[^>]*>/
    end
  end

  describe "member administration" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      member = Emisar.Fixtures.user_fixture()

      membership =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: member.id,
          role: "viewer"
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      %{owner: owner, account: account, member: member, membership: membership, lv: lv}
    end

    test "invite happy path reports and lists the invitee", %{lv: lv} do
      email = "newbie-#{System.unique_integer([:positive])}@example.com"

      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => email, "role" => "operator"}})
        |> render_submit()

      assert html =~ "Invited #{email}."
      assert html =~ email
    end

    test "inviting a suppressed address warns the inviter instead of a silent success", %{lv: lv} do
      # The address hard-bounced / was spam-flagged earlier, so the mailer
      # skips the send. The invite still exists, but the inviter must know the
      # email won't arrive — otherwise the member sits "unconfirmed" forever.
      email = "bounced-#{System.unique_integer([:positive])}@example.com"
      {:ok, _} = Emisar.Mail.suppress(email, :hard_bounce)

      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => email, "role" => "operator"}})
        |> render_submit()

      assert html =~ "email that address"
      assert html =~ "send them the join link another way"
      refute html =~ "Invited #{email}."
    end

    test "change_role promotes the member", %{lv: lv, membership: membership} do
      html =
        render_click(lv, "change_role", %{"membership_id" => membership.id, "role" => "operator"})

      assert html =~ "Role updated."
      assert Emisar.Repo.reload!(membership).role == :operator
    end

    test "the role dropdown offers every OTHER role and omits the current one", %{
      lv: lv,
      membership: membership
    } do
      # The member is seeded as a viewer; the role dropdown (a <.dropdown> matching
      # the Actions menu) carries a change_role item for every role EXCEPT the
      # current one. Scope to this member's items via phx-value-membership_id — the
      # invite panel carries its own (unrelated) role <select>.
      assert membership.role == :viewer

      for role <- ~w(operator admin owner) do
        assert has_element?(
                 lv,
                 "button[phx-click='change_role'][phx-value-membership_id='#{membership.id}'][phx-value-role='#{role}']"
               )
      end

      # The current role is not offered as a change target.
      refute has_element?(
               lv,
               "button[phx-click='change_role'][phx-value-membership_id='#{membership.id}'][phx-value-role='viewer']"
             )
    end

    test "each role item confirms the privilege grant before changing", %{
      lv: lv,
      membership: membership
    } do
      # Every other team action confirms; each role item must too, so an admin
      # can't fat-finger an escalation. The dialog fires only on a real pick (the
      # item's click), never on opening the control. The handler still authorizes.
      assert has_element?(
               lv,
               "button[phx-click='change_role'][phx-value-membership_id='#{membership.id}'][data-confirm]"
             )
    end

    test "an unknown role value is rejected", %{lv: lv, membership: membership} do
      html =
        render_click(lv, "change_role", %{"membership_id" => membership.id, "role" => "root"})

      assert html =~ "Unknown role."
      assert Emisar.Repo.reload!(membership).role == :viewer
    end

    test "suspend then reinstate round-trips", %{lv: lv, membership: membership} do
      assert render_click(lv, "suspend", %{"membership_id" => membership.id}) =~
               "Access suspended."

      assert Emisar.Repo.reload!(membership).disabled_at

      assert render_click(lv, "reinstate", %{"membership_id" => membership.id}) =~
               "Access restored."

      refute Emisar.Repo.reload!(membership).disabled_at
    end

    test "the Suspended chip appears on a suspended row and clears on reinstate", %{
      lv: lv,
      membership: membership
    } do
      # closes TEAM-006-T01
      # The roster reflects the state change live — the "Suspended" chip is the
      # visible signal the row is disabled.
      refute render(lv) =~ "Suspended"

      suspended = render_click(lv, "suspend", %{"membership_id" => membership.id})
      assert suspended =~ "Suspended"

      restored = render_click(lv, "reinstate", %{"membership_id" => membership.id})
      refute restored =~ "Suspended"
    end

    test "remove soft-deletes the membership through the typed-confirm dialog", %{
      lv: lv,
      member: member,
      membership: membership
    } do
      # Drive the dialog: type the member's email, then Confirm.
      dialog = "remove-member-#{membership.id}"
      type_confirm_token(lv, dialog, member.email)
      assert confirm_dialog(lv, dialog, "Remove member") =~ "Member removed."
      assert Emisar.Repo.reload!(membership).deleted_at
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
      # closes TEAM-005-T04
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

  describe "invite form live validation (phx-change)" do
    test "a blank email surfaces an inline error via phx-change, not a flash", %{conn: conn} do
      # closes TEAM-003-T02
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      # The live-validation path (phx-change="validate") shows the field error as
      # the operator types/clears — before they ever submit.
      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => "", "role" => "operator"}})
        |> render_change()

      assert html =~ "can&#39;t be blank"
      refute html =~ "Could not send invitation"
    end

    test "a malformed email surfaces inline via phx-change", %{conn: conn} do
      # closes TEAM-003-T03
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      html =
        lv
        |> form("#invite_form", %{"invite" => %{"email" => "b ob@x.com", "role" => "operator"}})
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end

    test "a role outside the allowed set is rejected with no membership created", %{conn: conn} do
      # closes TEAM-003-T04
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      email = "rolecheck-#{System.unique_integer([:positive])}@example.com"

      # The role <select> only offers valid roles, so push the event directly to
      # forge an out-of-set role. validate_inclusion fails, the invite never
      # reaches the context, and the form re-renders with the error instead.
      html =
        render_submit(lv, "invite", %{"invite" => %{"email" => email, "role" => "superadmin"}})

      assert html =~ "is invalid"
      refute html =~ "Invited #{email}."
      assert {:error, :not_found} = Emisar.Users.fetch_user_by_email(email)
    end
  end

  describe "reset a member's 2FA" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      member = Emisar.Fixtures.user_fixture()

      membership =
        Emisar.Fixtures.membership_fixture(
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
      refute has_element?(lv, "button[phx-click='reset_mfa']")

      enroll_mfa(member)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert has_element?(
               lv,
               "button[phx-click='reset_mfa'][phx-value-membership_id='#{membership.id}']"
             )
    end

    test "an owner resets the member's 2FA and they must re-enroll", %{
      conn: conn,
      account: account,
      member: member,
      membership: membership
    } do
      enroll_mfa(member)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      html = render_click(lv, "reset_mfa", %{"membership_id" => membership.id})

      assert html =~ "2FA reset"
      reloaded = Emisar.Repo.reload!(member)
      assert is_nil(reloaded.mfa_enabled_at)
      refute Emisar.Auth.mfa_required?(reloaded)
    end
  end

  describe "account-wide MFA toggle" do
    test "an owner without MFA hits the lockout guard", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      html = render_click(lv, "toggle_require_mfa", %{})

      assert html =~ "Enable MFA on your own profile first"
    end

    test "an owner with MFA enforces it account-wide", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)

      secret = Emisar.Auth.generate_mfa_secret()

      {:ok, _user, _codes} =
        Emisar.Auth.enable_mfa(
          secret,
          NimbleTOTP.verification_code(secret),
          Emisar.Fixtures.subject_for(owner, account)
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      assert render_click(lv, "toggle_require_mfa", %{}) =~ "Account-wide MFA enforced."
      assert Emisar.Repo.reload!(account).require_mfa
    end

    test "a non-owner is refused at the event level", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)

      admin = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(admin) |> live(~p"/app/#{account}/settings/team")

      html = render_click(lv, "toggle_require_mfa", %{})

      assert html =~ "Only the account owner can change this setting."
      refute Emisar.Repo.reload!(account).require_mfa
    end

    test "the toggle is a role=switch with aria-checked reflecting state, and still fires",
         %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      enroll_mfa(owner)

      # Off: a screen reader announces it as an unchecked switch.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      switch = element(lv, ~s(button[phx-click="toggle_require_mfa"]))
      assert html =~ ~s(role="switch")
      assert render(switch) =~ ~s(aria-checked="false")
      # The accessible name names the control (a placeholder/visible label
      # would otherwise be the only cue).
      assert html =~ ~s(aria-label="Enforce 2FA account-wide")

      # Clicking the switch fires the (server-authz-gated) handler.
      assert render_click(switch) =~ "Account-wide MFA enforced."
      assert Emisar.Repo.reload!(account).require_mfa

      # On: the switch now reports aria-checked="true".
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")
      assert html =~ ~s(aria-checked="true")
    end
  end

  describe "2FA enrollment stat" do
    test "renders account-wide enrollment, not just the visible page", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)

      member = Emisar.Fixtures.user_fixture()
      member |> Ecto.Changeset.change(mfa_enabled_at: DateTime.utc_now()) |> Emisar.Repo.update()

      Emisar.Fixtures.membership_fixture(
        account_id: account.id,
        user_id: member.id,
        role: "admin"
      )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      # Owner (unenrolled) + the enrolled member → 1 of 2, 1 without. The
      # counts come from Accounts.team_mfa_stats (account-wide), not @memberships.
      assert html =~ "2FA enrolled:"
      assert html =~ "1 without 2FA"
    end
  end

  describe "deliverability (email suppression) badge" do
    test "flags a member whose email is on the suppression list", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Emisar.Mail.suppress(user.email, :hard_bounce, "bounce")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "Email bouncing"
      assert html =~ "Contact support to clear it"
    end

    test "shows no badge when no member email is suppressed", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      refute html =~ "Email bouncing"
    end
  end

  describe "member-row timestamps render through <.local_time>" do
    test "the joined + sign-in times are hook-driven, with the prefix space kept", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      # A member who HAS signed in, so the "last sign-in <time>" branch renders
      # (the harness owner has no recorded sign-in → "never signed in").
      member = Emisar.Fixtures.user_fixture()

      member
      |> Ecto.Changeset.change(last_sign_in_at: DateTime.utc_now())
      |> Emisar.Repo.update!()

      Emisar.Fixtures.membership_fixture(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      # Both relative times render as the viewer-local <time> (consistent with
      # the rest of the app), not a static server string.
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-format="relative")
      # Mid-sentence spacing survives the formatter's line-break (the {" "}
      # guard): "joined <time>" and "last sign-in <time>", never abutting.
      assert html =~ ~r/joined\s<time/
      refute html =~ ~r/joined<time/
      assert html =~ ~r/last sign-in\s<time/
      refute html =~ ~r/last sign-in<time/
    end

    test "a member who has never signed in shows the static 'never signed in'", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      # A fresh, never-signed-in teammate — last_sign_in_at stays nil.
      member = Emisar.Fixtures.user_fixture()

      Emisar.Fixtures.membership_fixture(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team")

      assert html =~ "never signed in"
    end
  end

  describe "real-time roster updates (PubSub)" do
    test "an unrelated handle_info message is ignored, not crashed", %{conn: conn} do
      # closes TEAM-014-T04
      # The badge/fleet on_mount hooks forward account-topic broadcasts to every
      # LV, so TeamLive must carry the mandatory handle_info(_, socket) catch-all
      # (a missing one crashes the socket on the first stray message).
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")

      send(lv.pid, {:some_unrelated_event, :payload})

      # The process survived and still renders — render/1 raises if the socket died.
      assert render(lv) =~ "Invite a member"
    end

    test "the disconnected (dead) render shows the loading state, never the roster", %{conn: conn} do
      # closes TEAM-014-T05 TEAM-001-T11
      # handle_params gates the roster reads (and mount the subscribe) behind
      # connected?/1 (IL-18) — so the dead render a plain GET produces must show
      # <.loading_state>, with no member rows read or rendered. A teammate is
      # seeded precisely so "no roster on the dead render" is meaningful.
      {conn, _user, account} = register_and_log_in(conn, %{account: %{name: "DeadRenderOrg"}})

      teammate = Emisar.Fixtures.user_fixture(%{full_name: "Deadrender Teammate"})

      _ =
        Emisar.Fixtures.membership_fixture(
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
      # closes TEAM-001-T07 TEAM-001-T08
      # A garbage `after` cursor makes the keyset read return
      # {:error, :invalid_cursor}; load/2 retries once with %{} (since the params
      # were non-empty), so the page recovers and renders the roster instead of
      # 500-ing or landing on the load-error empty state.
      {conn, _user, account} = register_and_log_in(conn, %{account: %{name: "RecoverOrg"}})

      teammate = Emisar.Fixtures.user_fixture(%{full_name: "Recover Teammate"})

      _ =
        Emisar.Fixtures.membership_fixture(
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
      # closes TEAM-003-T05
      # The invite changeset is purely UX — a viewer can pass every field-level
      # check (valid email, valid role) and the `invite` handler must STILL deny
      # them via can_manage?, never creating a membership.
      {_owner_conn, _owner, account} = register_and_log_in(conn, %{account: %{name: "ValOrg"}})

      viewer = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
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
      assert {:error, :not_found} = Emisar.Users.fetch_user_by_email(email)
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
      # closes TEAM-004-T04
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
      # closes TEAM-005-T03 TEAM-007-T02 TEAM-011-T03
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
          "groups" => [],
          "runners" => []
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
end
