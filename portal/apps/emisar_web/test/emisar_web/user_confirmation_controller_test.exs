defmodule EmisarWeb.UserConfirmationControllerTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Auth, Repo, Users}

  describe "GET /confirm/:token" do
    test "confirms a signed-in (but unconfirmed) user and returns them to the app", %{conn: conn} do
      # Regression: clicking the confirm link while signed in used to bounce
      # off :redirect_if_user_is_authenticated without ever consuming the
      # token, leaving the account unconfirmed and the banner stuck.
      user = unconfirmed_user()
      refute user.confirmed_at
      token = Auth.issue_confirmation_token!(user)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/confirm/#{token}")

      assert redirected_to(conn) == ~p"/app"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Email confirmed."
      assert Repo.reload!(user).confirmed_at
    end

    test "confirms a signed-out user and sends them to sign in", %{conn: conn} do
      user = unconfirmed_user()
      token = Auth.issue_confirmation_token!(user)

      conn = get(conn, ~p"/confirm/#{token}")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Sign in to continue"
      assert Repo.reload!(user).confirmed_at
    end

    test "rejects an invalid or already-used token", %{conn: conn} do
      conn = get(conn, ~p"/confirm/this-is-not-a-real-token")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired or was already used"
    end
  end

  defp unconfirmed_user do
    {:ok, user} =
      Users.register_user(%{
        email: "unconfirmed-#{System.unique_integer([:positive])}@example.com",
        full_name: "Unconfirmed User",
        password: "very-long-password-1234"
      })

    user
  end
end
