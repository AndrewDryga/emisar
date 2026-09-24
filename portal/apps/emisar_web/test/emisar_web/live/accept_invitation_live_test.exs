defmodule EmisarWeb.AcceptInvitationLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth}

  # Mints a pending invitation and returns its token. The invitee is a
  # brand-new email (anonymous-accept flow), so the accept page renders
  # the name-only join form (passwordless — a sign-in link is emailed on accept).
  defp invitation_token(account, owner) do
    email = "invitee-#{System.unique_integer([:positive])}@example.com"
    subject = owner_subject(owner, account)

    {:ok, %{invitation_token: token}} =
      Accounts.invite_user_to_account(
        Fixtures.Accounts.invitation_attrs(
          email: email,
          role: "operator",
          runner_access_mode: "all"
        ),
        subject
      )

    token
  end

  describe "token gate" do
    test "an invitation neither exposes nor changes an existing personal name", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      person = Fixtures.Users.create_user(full_name: "Private Personal Name")
      elsewhere = Fixtures.Memberships.create_membership(user_id: person.id)

      {:ok, invitation} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: person.email, role: "viewer"),
          owner_subject(owner, account)
        )

      {:ok, lv, html} = live(build_conn(), ~p"/accept_invitation/#{invitation.invitation_token}")
      refute html =~ "Private Personal Name"
      assert has_element?(lv, "#accept_form", "Your name in this workspace")

      lv |> form("#accept_form", member: %{display_name: "Work Name"}) |> render_submit()

      assert Emisar.Repo.reload!(invitation.membership).display_name == "Work Name"
      assert Emisar.Repo.reload!(person).full_name == "Private Personal Name"
      assert Emisar.Repo.reload!(elsewhere) == elsewhere
    end

    test "a bogus token renders the Invitation-unavailable page with cause-neutral copy", %{
      conn: _conn
    } do
      {:ok, _lv, html} = live(build_conn(), ~p"/accept_invitation/not-a-real-token")

      # The state renders ON the page (inline-errors house rule) with a
      # recovery action. Cause-neutral: a mistyped/garbage token shouldn't
      # claim "expired", and the page names no account.
      assert html =~ "Invitation unavailable"
      assert html =~ "isn&#39;t valid or is no longer available"
      assert html =~ "Go to sign in"
      refute html =~ "expired"
    end

    test "a blank (whitespace-only) token renders the same unavailable page", %{conn: _conn} do
      # the route carries the token as a path segment, so the
      # empty case is a whitespace-only token: `fetch_invitation_by_token` requires a
      # real (non-empty) binary and never matches one — same cause-neutral page,
      # no invite resolvable from a blank token.
      {:ok, _lv, html} = live(build_conn(), ~p"/accept_invitation/#{"   "}")

      assert html =~ "Invitation unavailable"
    end

    test "an expired invitation names the state and asks for a fresh one", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      {:ok, membership} = Accounts.fetch_invitation_by_token(token)
      nine_days_ago = DateTime.add(DateTime.utc_now(), -9 * 24 * 3600, :second)

      {:ok, _} =
        membership |> Ecto.Changeset.change(inserted_at: nine_days_ago) |> Emisar.Repo.update()

      {:ok, _lv, html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      # The bearer holds the real emailed token, so naming the expiry is not an
      # enumeration oracle — but the page still names no account.
      assert html =~ "Invitation expired"
      assert html =~ "send a fresh one"
      refute html =~ account.name
    end
  end

  describe "anonymous accept" do
    test "renders the join offer and accepts with a valid registration", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      {:ok, lv, html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      assert html =~ account.name
      # The human role label, never the raw atom.
      assert html =~ "Operator"
      assert html =~ "invitee-"
      # Passwordless: the join form sets a name, not a password.
      refute html =~ ~s|name="user[password]"|

      params = %{"member" => %{"display_name" => "New Person"}}

      {:ok, pending_membership} = Accounts.fetch_invitation_by_token(token)
      assert is_nil(pending_membership.user_id)

      # A valid accept arms the hidden POST to the magic-link start
      # (phx-trigger-action), so the invitee gets a one-time sign-in link.
      html = lv |> form("#accept_form", params) |> render_submit()
      assert html =~ ~s|action="/sign_in/magic/start"|
      assert html =~ ~s|name="return_to" value="/app/#{account.slug}"|

      # Accepting burns the token and links a new login for the invited address,
      # which the magic link then proves.
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}

      accepted = Emisar.Repo.reload!(pending_membership)
      {:ok, user} = Emisar.Users.fetch_user_by_email(pending_membership.invitation_sent_to)
      assert accepted.user_id == user.id
      assert accepted.display_name == "New Person"
      assert is_nil(user.full_name)
      assert is_nil(user.confirmed_at)
    end

    test "the invitee finishes with the emailed sign-in and opens the workspace", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)
      {:ok, invitation} = Accounts.fetch_invitation_by_token(token)

      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      lv
      |> form("#accept_form", %{"member" => %{"display_name" => "New Person"}})
      |> render_submit()

      requested =
        post(build_conn(), ~p"/sign_in/magic/start", %{
          "user" => %{"email" => invitation.invitation_sent_to},
          "return_to" => ~p"/app/#{account}"
        })

      assert_received {:email, sent}
      assert sent.to == [{"", invitation.invitation_sent_to}]
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      completed = get(recycle(requested), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert get_session(completed, :user_token)
      {:ok, user} = Emisar.Users.fetch_user_by_email(invitation.invitation_sent_to)
      assert user.confirmed_at
      assert Emisar.Repo.reload!(invitation).user_id == user.id
      assert html_response(get(recycle(completed), ~p"/app/#{account}"), 200) =~ "New Person"
    end

    test "a signed-out visitor pushing accept_existing is a no-op, not a crash", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      # `mark_invitation_accepted/3` requires a `%Users.User{}`; with no signed-in
      # user this push used to raise FunctionClauseError and kill the socket.
      render_click(lv, "accept_existing", %{})

      assert render(lv) =~ "accept_form"
      assert {:ok, _membership} = Accounts.fetch_invitation_by_token(token)
    end

    test "an accept that lost the race to a second link-holder lands on the terminal state", %{
      conn: conn
    } do
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      # A second holder of the same emailed link accepts while this tab sits
      # on the form, burning the token.
      {:ok, membership} = Accounts.fetch_invitation_by_token(token)

      {:ok, _} =
        Accounts.accept_invitation(membership, token, %{"display_name" => "First Acceptor"})

      html =
        lv
        |> form("#accept_form", %{"member" => %{"display_name" => "Second Acceptor"}})
        |> render_submit()

      # Terminal state with a recovery action — not a transient flash over a
      # form that can never succeed.
      assert html =~ "Invitation unavailable"
      assert html =~ "no longer available"
      assert html =~ "Go to sign in"
      refute html =~ "accept_form"
    end

    test "a mounted old link cannot accept after an administrator resends", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      subject = owner_subject(owner, account)

      {:ok, %{membership: membership, invitation_token: old_token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "rotated-#{System.unique_integer([:positive])}@example.com",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      {:ok, old_live, _html} = live(build_conn(), ~p"/accept_invitation/#{old_token}")

      assert {:ok, %{invitation_token: new_token}} =
               Accounts.resend_account_invitation(membership, subject)

      old_html =
        old_live
        |> form("#accept_form", %{"member" => %{"display_name" => "Old Link"}})
        |> render_submit()

      assert old_html =~ "Invitation unavailable"
      refute old_html =~ "accept_form"

      {:ok, new_live, _html} = live(build_conn(), ~p"/accept_invitation/#{new_token}")

      new_live
      |> form("#accept_form", %{"member" => %{"display_name" => "New Link"}})
      |> render_submit()

      accepted = membership |> Emisar.Repo.reload!() |> Emisar.Repo.preload(:user)
      assert accepted.display_name == "New Link"
      assert is_nil(accepted.user.full_name)
    end

    test "a login that moved off the invited address neither sees nor accepts the invitation",
         %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      original_email = "old-link-#{System.unique_integer([:positive])}@example.com"
      current_email = "current-#{System.unique_integer([:positive])}@example.com"
      moved = Fixtures.Users.create_user(email: original_email)

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: original_email,
            role: "operator",
            runner_access_mode: "all"
          ),
          owner_subject(owner, account)
        )

      moved = moved |> Fixtures.Users.update_email(current_email) |> Fixtures.Users.confirm_user()

      # The invitation still belongs to its address, and names only that address.
      {:ok, _live, html} = live(build_conn(), ~p"/accept_invitation/#{token}")
      assert html =~ original_email
      refute html =~ current_email

      signed_in = log_in_user(build_conn(), moved)
      {:ok, _live, html} = live(signed_in, ~p"/accept_invitation/#{token}")
      assert html =~ "Sign in with your invited email"

      rejected = post(signed_in, ~p"/accept_invitation/#{token}", %{})
      assert redirected_to(rejected) == ~p"/accept_invitation/#{token}"
      assert {:ok, pending} = Accounts.fetch_invitation_by_token(token)
      assert is_nil(pending.user_id)
    end
  end

  describe "invited email is fixed" do
    test "a tampered hidden email is ignored — the server keeps the invited address", %{
      conn: conn
    } do
      # the anonymous form shows the invited email as a
      # read-only hidden field, but acceptance casts ONLY the workspace name
      # (never an email), so a client that rewrites the hidden value
      # can't redirect the invitation onto a different address: the
      # registered/confirmed user still carries the membership's invited email.
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      {:ok, invited} = Accounts.fetch_invitation_by_token(token)
      invited_email = invited.invitation_sent_to

      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      # Dispatch the `accept` event directly with a crafted payload whose
      # `user[email]` is an attacker-chosen address — bypassing the form's own
      # hidden-field guard to prove the SERVER (not just the client) ignores it.
      params = %{
        "user" => %{"email" => "attacker@evil.test"},
        "member" => %{
          "email" => "attacker@evil.test",
          "display_name" => "New Person"
        }
      }

      render_submit(lv, "accept", params)

      {:ok, user} = Emisar.Users.fetch_user_by_email(invited_email)
      assert Emisar.Repo.reload!(invited).user_id == user.id
      assert Emisar.Users.fetch_user_by_email("attacker@evil.test") == {:error, :not_found}
    end
  end

  describe "member-only SSO session" do
    test "is asked to sign out first and cannot accept from this browser", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)
      {:ok, invitation} = Accounts.fetch_invitation_by_token(token)

      {_sso_owner, sso_account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = Fixtures.SSO.create_identity_provider(account_id: sso_account.id)
      member = Fixtures.Memberships.create_unlinked_membership(account_id: sso_account.id)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: sso_account.id,
          provider_id: provider.id,
          membership: member
        )

      member_only =
        build_conn()
        |> init_test_session(%{})
        |> put_session(:user_token, Fixtures.Auth.create_member_session_token!(member, identity))

      {:ok, lv, html} = live(member_only, ~p"/accept_invitation/#{token}")

      assert html =~ invitation.invitation_sent_to
      assert html =~ "without a personal login"
      assert html =~ "Sign out"
      refute has_element?(lv, "#accept_form")
      refute has_element?(lv, "#accept_existing_form")

      # The rendered branch is not the gate: a crafted accept is a no-op, and
      # HTTP acceptance needs a personal login.
      render_click(lv, "accept", %{"member" => %{"display_name" => "Member Only"}})
      rejected = post(member_only, ~p"/accept_invitation/#{token}", %{})
      assert redirected_to(rejected) == ~p"/accept_invitation/#{token}"

      assert Emisar.Repo.reload!(invitation) == invitation

      assert Emisar.Users.fetch_user_by_email(invitation.invitation_sent_to) ==
               {:error, :not_found}
    end
  end

  describe "signed-in accept" do
    setup %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      %{owner: owner, account: account}
    end

    test "HTTP acceptance preserves existing proof and opens the new workspace after fresh sign-in",
         %{
           owner: owner,
           account: account
         } do
      # The invitee is already signed in to a different account. Accepting must
      # target the invitation instead of following the stale account session.
      invitee = Fixtures.Users.create_user()
      old_account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: old_account.id,
        user_id: invitee.id,
        role: "owner"
      )

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: invitee.email,
            role: "viewer",
            runner_access_mode: "all"
          ),
          owner_subject(owner, account)
        )

      signed_in =
        build_conn()
        |> log_in_user(invitee)
        |> put_session(:current_account_id, old_account.id)

      {:ok, lv, html} = live(signed_in, ~p"/accept_invitation/#{token}")

      assert html =~ "You&#39;re signed in as"
      assert has_element?(lv, "#accept_existing_form[action='/accept_invitation/#{token}']")
      raw = get_session(signed_in, :user_token)
      other = log_in_user(build_conn(), invitee)
      other_raw = get_session(other, :user_token)
      shown = get(signed_in, ~p"/accept_invitation/#{token}")

      [csrf] =
        shown.resp_body
        |> LazyHTML.from_document()
        |> LazyHTML.query("#accept_existing_form input[name='_csrf_token']")
        |> LazyHTML.attribute("value")

      protected = shown |> recycle() |> put_private(:plug_skip_csrf_protection, false)
      assert_error_sent(403, fn -> post(protected, ~p"/accept_invitation/#{token}", %{}) end)
      assert {:ok, _pending} = Accounts.fetch_invitation_by_token(token)
      accepted = post(protected, ~p"/accept_invitation/#{token}", %{_csrf_token: csrf})
      assert redirected_to(accepted) == ~p"/session/recover"
      assert Emisar.Repo.reload!(invitation).user_id == invitee.id
      assert get_session(accepted, :user_token) == raw
      assert html_response(get(accepted, ~p"/session/recover"), 200) =~ "Invitation accepted"
      assert html_response(get(accepted, ~p"/app/#{old_account}"), 200)

      for existing <- [raw, other_raw] do
        assert {:ok, session} = Auth.fetch_session_by_token(existing)

        assert Accounts.fetch_membership_by_account_id_or_slug(account.id, session) ==
                 {:error, :not_found}
      end

      replayed = post(accepted, ~p"/accept_invitation/#{token}", %{_csrf_token: csrf})
      assert redirected_to(replayed) == ~p"/accept_invitation/#{token}"

      restarted = post(accepted, ~p"/session/recover", %{_csrf_token: csrf})
      assert redirected_to(restarted) == ~p"/sign_in"
      assert {:error, :not_found} = Auth.fetch_session_by_token(raw)
      assert {:ok, _} = Auth.fetch_session_by_token(other_raw)
      fresh = restarted |> recycle() |> log_in_user(invitee)
      assert html_response(get(fresh, ~p"/app/#{account}"), 200)
      assert html_response(get(fresh, ~p"/app/#{old_account}"), 200)

      # Accepted: the token is burned.
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end

    test "an accept whose invitation was revoked mid-session lands on the terminal state", %{
      owner: owner,
      account: account
    } do
      invitee = Fixtures.Users.create_user()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: invitee.email,
            role: "viewer",
            runner_access_mode: "all"
          ),
          owner_subject(owner, account)
        )

      signed_in = build_conn() |> log_in_user(invitee)
      {:ok, _lv, _html} = live(signed_in, ~p"/accept_invitation/#{token}")

      # An admin revokes the invitation while the invitee's tab sits open.
      {:ok, membership} = Accounts.fetch_invitation_by_token(token)
      Fixtures.Memberships.mark_membership_as_deleted(membership)

      rejected = post(signed_in, ~p"/accept_invitation/#{token}", %{})
      assert redirected_to(rejected) == ~p"/accept_invitation/#{token}"
      html = rejected |> get(~p"/accept_invitation/#{token}") |> html_response(200)

      assert html =~ "Invitation unavailable"
      assert html =~ "Go to sign in"
      refute html =~ "Accept invitation"
    end

    test "an invited address matches the signed-in login's in any letter case", %{
      owner: owner,
      account: account
    } do
      invitee =
        Fixtures.Users.create_user(
          email: "casey-#{System.unique_integer([:positive])}@example.com"
        )

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: String.upcase(invitee.email), role: "viewer"),
          owner_subject(owner, account)
        )

      signed_in = build_conn() |> log_in_user(invitee)
      {:ok, lv, html} = live(signed_in, ~p"/accept_invitation/#{token}")

      assert html =~ "You&#39;re signed in as"
      assert has_element?(lv, "#accept_existing_form")

      accepted = post(signed_in, ~p"/accept_invitation/#{token}", %{})
      assert redirected_to(accepted) == ~p"/session/recover"
      assert Emisar.Repo.reload!(invitation).user_id == invitee.id
    end

    test "a login that already holds a seat is told so, and the invitation stays open", %{
      owner: owner,
      account: account
    } do
      seated = Fixtures.Users.create_user()

      # The seat lists another contact, so the address reached an invitation.
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: seated.id,
        contact_email: "work-#{System.unique_integer([:positive])}@example.com"
      )

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: seated.email, role: "admin"),
          owner_subject(owner, account)
        )

      rejected = build_conn() |> log_in_user(seated) |> post(~p"/accept_invitation/#{token}", %{})

      assert redirected_to(rejected) == ~p"/accept_invitation/#{token}"

      assert Phoenix.Flash.get(rejected.assigns.flash, :error) ==
               EmisarWeb.AcceptInvitationLive.already_member_message()

      assert Emisar.Repo.reload!(invitation) == invitation
    end

    test "a DIFFERENT signed-in user gets the wrong-account screen, not the accept", %{
      owner: owner,
      account: account
    } do
      token = invitation_token(account, owner)

      bystander = Fixtures.Users.create_user()

      {:ok, _lv, html} =
        build_conn() |> log_in_user(bystander) |> live(~p"/accept_invitation/#{token}")

      assert html =~ "Sign in with your invited email"
      assert html =~ "Sign out"
      refute html =~ "accept_existing_form"
    end

    test "a signed-in stranger cannot burn the invitation with a crafted accept", %{
      owner: owner,
      account: account
    } do
      token = invitation_token(account, owner)
      {:ok, pending_membership} = Accounts.fetch_invitation_by_token(token)
      bystander = Fixtures.Users.create_user()

      {:ok, lv, _html} =
        build_conn() |> log_in_user(bystander) |> live(~p"/accept_invitation/#{token}")

      # The wrong-account screen renders no accept control, but the HANDLER is
      # the gate: the anonymous branch would otherwise provision the invitee
      # and write the bystander's name onto the invited membership.
      render_click(lv, "accept", %{"member" => %{"display_name" => "Bystander"}})

      for attempted <- [build_conn(), log_in_user(build_conn(), bystander)] do
        rejected = post(attempted, ~p"/accept_invitation/#{token}", %{})
        assert redirected_to(rejected) == ~p"/accept_invitation/#{token}"
      end

      assert {:ok, _still_pending} = Accounts.fetch_invitation_by_token(token)
      assert Emisar.Repo.reload!(pending_membership) == pending_membership

      assert Emisar.Users.fetch_user_by_email(pending_membership.invitation_sent_to) ==
               {:error, :not_found}
    end
  end
end
