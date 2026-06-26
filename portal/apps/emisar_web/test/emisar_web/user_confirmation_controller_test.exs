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

    test "a non-decodable token is uniformly invalid (base64 decode fails first)", %{conn: conn} do
      # a token that isn't valid base64 can't resolve to a
      # row, so `confirm_user_by_token` returns the same `:invalid_or_expired` as a
      # bad/expired one: one cause-neutral message, no confirmation.
      conn = get(conn, ~p"/confirm/!!!not-base64!!!")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired or was already used"
    end

    test "a session token presented at the confirm endpoint is uniformly invalid", %{
      conn: conn
    } do
      # tokens carry a `context`; the confirm consumer
      # matches `context == "confirm"`. A valid (but wrong-context) session token
      # confirms nothing — same uniform error as a bad token, and the user stays
      # unconfirmed. No cross-endpoint token reuse.
      user = unconfirmed_user()
      session_token = Auth.create_session_token!(user, :magic_link, false)

      conn = get(conn, ~p"/confirm/#{session_token}")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired or was already used"
      refute Repo.reload!(user).confirmed_at
    end

    test "a soft-deleted user cannot confirm", %{conn: conn} do
      # the confirm token resolves to no LIVE user once the
      # row is soft-deleted, so the link returns the same uniform invalid error
      # rather than flipping `confirmed_at` on a tombstoned account.
      user = unconfirmed_user()
      token = Auth.issue_confirmation_token!(user)

      {:ok, _} = user |> Users.User.Changeset.delete() |> Repo.update()

      conn = get(conn, ~p"/confirm/#{token}")

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired or was already used"
    end
  end

  defp unconfirmed_user do
    {:ok, user} =
      Users.register_user(%{
        email: "unconfirmed-#{System.unique_integer([:positive])}@example.com",
        full_name: "Unconfirmed User"
      })

    user
  end
end
