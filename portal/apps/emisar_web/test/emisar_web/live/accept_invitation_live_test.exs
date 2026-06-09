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
end
