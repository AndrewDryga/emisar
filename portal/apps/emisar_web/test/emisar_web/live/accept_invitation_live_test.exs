defmodule EmisarWeb.AcceptInvitationLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Accounts

  # Mints a pending invitation and returns its token. The invitee is a
  # brand-new email (anonymous-accept flow), so the accept page renders
  # the name-only join form (passwordless — a sign-in link is emailed on accept).
  defp invitation_token(account, owner) do
    email = "invitee-#{System.unique_integer([:positive])}@example.com"
    subject = owner_subject(owner, account)

    {:ok, %{invitation_token: token}} =
      Accounts.invite_user_to_account(
        email,
        "operator",
        Accounts.RunnerAccess.all(),
        subject
      )

    token
  end

  describe "token gate" do
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
      assert html =~ "operator"
      assert html =~ "invitee-"
      # Passwordless: the join form sets a name, not a password.
      refute html =~ ~s|name="user[password]"|

      params = %{"user" => %{"full_name" => "New Person"}}

      {:ok, pending_membership} = Accounts.fetch_invitation_by_token(token, preload: [:user])

      # A valid accept arms the hidden POST to the magic-link start
      # (phx-trigger-action), so the invitee gets a one-time sign-in link.
      html = lv |> form("#accept_form", params) |> render_submit()
      assert html =~ ~s|action="/sign_in/magic/start"|

      # Accepting burns the token and completes the registration.
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}

      user = Emisar.Repo.reload!(pending_membership.user)
      assert user.full_name == "New Person"
      assert user.confirmed_at
    end
  end

  describe "invited email is fixed" do
    test "a tampered hidden email is ignored — the server keeps the invited address", %{
      conn: conn
    } do
      # the anonymous form shows the invited email as a
      # read-only hidden field, but the `accept` handler builds its attrs from ONLY
      # full_name (never `user[email]`), so a client that rewrites the hidden value
      # can't redirect the invitation onto a different address: the
      # registered/confirmed user still carries the membership's invited email.
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      {:ok, invited} = Accounts.fetch_invitation_by_token(token, preload: [:user])
      invited_email = invited.user.email

      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      # Dispatch the `accept` event directly with a crafted payload whose
      # `user[email]` is an attacker-chosen address — bypassing the form's own
      # hidden-field guard to prove the SERVER (not just the client) ignores it.
      params = %{
        "user" => %{
          "email" => "attacker@evil.test",
          "full_name" => "New Person"
        }
      }

      render_submit(lv, "accept", params)

      user = Emisar.Repo.reload!(invited.user)
      assert user.email == invited_email
      refute user.email == "attacker@evil.test"
      assert user.confirmed_at
    end
  end

  describe "signed-in accept" do
    setup %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      %{owner: owner, account: account}
    end

    test "the invitee accepts in place and lands in the app", %{owner: owner, account: account} do
      # The invitee is an already-registered user, signed in.
      invitee = Fixtures.Users.create_user()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          invitee.email,
          "viewer",
          Accounts.RunnerAccess.all(),
          owner_subject(owner, account)
        )

      {:ok, lv, html} =
        build_conn() |> log_in_user(invitee) |> live(~p"/accept_invitation/#{token}")

      assert html =~ "You&#39;re signed in as"

      render_click(lv, "accept_existing", %{})
      assert_redirect(lv, "/app")

      # Accepted: the token is burned.
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end

    test "a DIFFERENT signed-in user gets the wrong-account screen, not the accept", %{
      owner: owner,
      account: account
    } do
      token = invitation_token(account, owner)

      bystander = Fixtures.Users.create_user()

      {:ok, _lv, html} =
        build_conn() |> log_in_user(bystander) |> live(~p"/accept_invitation/#{token}")

      assert html =~ "Wrong account"
      assert html =~ "Sign out"
      refute html =~ "phx-click=\"accept_existing\""
    end
  end
end
