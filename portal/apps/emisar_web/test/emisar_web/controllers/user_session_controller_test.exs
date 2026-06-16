defmodule EmisarWeb.UserSessionControllerTest do
  use EmisarWeb.ConnCase, async: true

  describe "DELETE /sign_out" do
    test "logs the user out, clears the session, and invalidates the token", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      token = Plug.Conn.get_session(conn, :user_token)
      assert token

      conn = delete(conn, ~p"/sign_out")

      assert redirected_to(conn) == "/"
      refute Plug.Conn.get_session(conn, :user_token)
      # The token is actually killed server-side, not just dropped from the
      # session — a stolen copy can't be replayed.
      assert {:error, :not_found} = Emisar.Auth.fetch_user_and_token_by_session_token(token)
    end

    test "is a harmless redirect when no one is signed in", %{conn: conn} do
      conn = delete(conn, ~p"/sign_out")
      assert redirected_to(conn) == "/"
    end
  end

  describe "POST /sign_in?_action=registered (sign-up auto-login)" do
    test "flashes the confirmation-email notice so it isn't silent", %{conn: conn} do
      # register_and_log_in builds a real user+account; reuse the credentials in
      # a fresh, signed-out conn to drive the registration auto-login POST.
      {_logged_in, user, _account} = register_and_log_in(conn)

      conn =
        build_conn()
        |> post(~p"/sign_in?_action=registered", %{
          "user" => %{"email" => user.email, "password" => "very-long-password-here"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmation link to #{user.email}"
    end
  end
end
