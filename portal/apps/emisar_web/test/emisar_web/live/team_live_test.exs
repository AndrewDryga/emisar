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
