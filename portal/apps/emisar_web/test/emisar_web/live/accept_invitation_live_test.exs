defmodule EmisarWeb.AcceptInvitationLiveTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Accounts

  # Mints a pending invitation and returns its token. The invitee is a
  # brand-new email (anonymous-accept flow), so the accept page renders
  # the password-set form.
  defp invitation_token(account, owner) do
    email = "invitee-#{System.unique_integer([:positive])}@example.com"
    subject = owner_subject(owner, account)

    {:ok, %{invitation_token: token}} =
      Accounts.invite_user_to_account(email, "operator", subject)

    token
  end

  describe "anonymous accept form validation" do
    test "a too-short password renders inline on the field, not in a flash", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      # Fresh, signed-out visitor — the anonymous password-set form renders.
      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      params = %{"user" => %{"full_name" => "New Person", "password" => "short"}}
      html = lv |> form("#accept_form", params) |> render_submit()

      assert html =~ "should be at least 12 character"
      # Old flash copy ("Could not accept: ...") is gone.
      refute html =~ "Could not accept"
    end
  end

  describe "token gate" do
    test "a bogus token bounces to sign-in with cause-neutral copy", %{conn: _conn} do
      assert {:error, {:live_redirect, %{to: "/sign_in", flash: flash}}} =
               live(build_conn(), ~p"/accept_invitation/not-a-real-token")

      # Cause-neutral: a mistyped/garbage token shouldn't claim "expired".
      assert flash["error"] =~ "isn't valid"
      refute flash["error"] =~ "expired"
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

      params = %{
        "user" => %{"full_name" => "New Person", "password" => "a-long-enough-password"}
      }

      {:ok, pending_membership} = Accounts.fetch_invitation_by_token(token, preload: [:user])

      # A valid accept arms the hidden POST to /sign_in (phx-trigger-action).
      html = lv |> form("#accept_form", params) |> render_submit()
      assert html =~ ~s|action="/sign_in?_action=invitation_accepted"|

      # Accepting burns the token and completes the registration.
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}

      user = Emisar.Repo.reload!(pending_membership.user)
      assert user.full_name == "New Person"
      assert user.confirmed_at
    end
  end

  describe "signed-in accept" do
    test "the invitee accepts in place and lands in the app", %{conn: conn} do
      {_owner_conn, owner, account} = register_and_log_in(conn)

      # The invitee is an already-registered user, signed in.
      invitee = Emisar.Fixtures.user_fixture()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(invitee.email, "viewer", owner_subject(owner, account))

      {:ok, lv, html} =
        build_conn() |> log_in_user(invitee) |> live(~p"/accept_invitation/#{token}")

      assert html =~ "You&#39;re signed in as"

      render_click(lv, "accept_existing", %{})
      assert_redirect(lv, "/app")

      # Accepted: the token is burned.
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end

    test "a DIFFERENT signed-in user gets the wrong-account screen, not the accept", %{
      conn: conn
    } do
      {_owner_conn, owner, account} = register_and_log_in(conn)
      token = invitation_token(account, owner)

      bystander = Emisar.Fixtures.user_fixture()

      {:ok, _lv, html} =
        build_conn() |> log_in_user(bystander) |> live(~p"/accept_invitation/#{token}")

      assert html =~ "Wrong account"
      assert html =~ "Sign out"
      refute html =~ "phx-click=\"accept_existing\""
    end
  end
end
