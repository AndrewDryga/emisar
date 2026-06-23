defmodule EmisarWeb.ResetPasswordLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "request form validation" do
    test "a malformed email surfaces inline via phx-change, not a flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/reset_password")

      html =
        lv
        |> form("#request_form", %{"user" => %{"email" => "not-an-email"}})
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end

    test "submitting keeps the deliberately-vague anti-enumeration message", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/reset_password")

      html =
        lv
        |> form("#request_form", %{"user" => %{"email" => "nobody@example.com"}})
        |> render_submit()

      assert html =~ "is registered, a reset link is on its way"
    end

    test "the email field is required (a blank email is blocked client-side, no mint)", %{
      conn: conn
    } do
      # like the magic-link send, the reset-request handler has
      # no `else` and never server-validates a blank email (it falls through to the
      # same anti-enumeration panel). A blank submit is blocked by the `required` HTML
      # attribute on the email input — the gate is the browser attr, not a changeset.
      {:ok, _lv, html} = live(conn, ~p"/reset_password")

      assert html =~ ~r/<input[^>]*name="user\[email\]"[^>]*required/
    end
  end

  describe "reset form validation" do
    test "a too-short password renders inline on the field, not in a flash", %{conn: conn} do
      # The token is only checked AFTER the changeset validates, so an
      # invalid password never reaches the (here dummy) token lookup.
      {:ok, lv, _html} = live(conn, ~p"/reset_password/sometoken")

      html =
        lv
        |> form("#reset_form", %{
          "user" => %{"password" => "short", "password_confirmation" => "short"}
        })
        |> render_submit()

      assert html =~ "should be at least 12 character"
      # Inline on the field, not a flash banner. (Can't refute the old flash
      # text here — the form's static hint also reads "Use at least 12
      # characters." — so assert the error-flash element is simply absent.)
      refute has_element?(lv, "#flash-error")
    end

    test "a confirmation mismatch renders inline on the confirmation field, not a flash", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/reset_password/sometoken")

      html =
        lv
        |> form("#reset_form", %{
          "user" => %{
            "password" => "a-perfectly-long-password",
            "password_confirmation" => "a-different-long-password"
          }
        })
        |> render_submit()

      assert html =~ "does not match password"
      refute html =~ "Passwords don&#39;t match."
    end
  end

  describe "successful reset" do
    test "lands on the branded sign-in when a return_to was threaded through (follow-up d)", %{
      conn: conn
    } do
      account = Emisar.Fixtures.account_fixture()
      user = Emisar.Fixtures.user_fixture()
      token = Emisar.Auth.issue_password_reset_token!(user, [], %Emisar.RequestContext{})

      {:ok, lv, _html} =
        live(conn, ~p"/reset_password/#{token}?#{[return_to: "/app/#{account.slug}"]}")

      result =
        lv
        |> form("#reset_form", %{
          "user" => %{
            "password" => "a-perfectly-long-password",
            "password_confirmation" => "a-perfectly-long-password"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == ~p"/app/#{account}/sign_in"
    end

    test "lands on the generic sign-in with no return_to", %{conn: conn} do
      user = Emisar.Fixtures.user_fixture()
      token = Emisar.Auth.issue_password_reset_token!(user, [], %Emisar.RequestContext{})

      {:ok, lv, _html} = live(conn, ~p"/reset_password/#{token}")

      result =
        lv
        |> form("#reset_form", %{
          "user" => %{
            "password" => "a-perfectly-long-password",
            "password_confirmation" => "a-perfectly-long-password"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/sign_in"}}} = result
    end
  end

  describe "token security" do
    test "a reused reset token is uniformly invalid on the second use", %{conn: conn} do
      # the reset deletes the token in the same txn, so a
      # replayed token (double-clicked link, reused link) finds no row and the
      # second attempt fails with the same uniform invalid-or-expired error.
      user = Emisar.Fixtures.user_fixture()
      token = Emisar.Auth.issue_password_reset_token!(user, [], %Emisar.RequestContext{})

      # First use consumes the token successfully.
      assert {:ok, _user} =
               Emisar.Auth.reset_user_password(
                 token,
                 "a-perfectly-long-password",
                 %Emisar.RequestContext{}
               )

      # Second use of the same token: the row is gone, so the LiveView submit
      # bounces back to the request page with the expired-link flash.
      {:ok, lv, _html} = live(conn, ~p"/reset_password/#{token}")

      result =
        lv
        |> form("#reset_form", %{
          "user" => %{
            "password" => "another-perfectly-long-password",
            "password_confirmation" => "another-perfectly-long-password"
          }
        })
        |> render_submit()

      # A successful reset push_navigates to /sign_in; a uniformly-invalid token
      # (reused, wrong-context, soft-deleted user) instead bounces back to
      # /reset_password — the destination is the cause-neutral tell.
      assert {:error, {:live_redirect, %{to: "/reset_password"}}} = result
    end

    test "a confirm/magic token presented at the reset endpoint is uniformly invalid (wrong context)",
         %{conn: conn} do
      # tokens are bound to a `context`; the reset consumer
      # matches `context == "reset_password"`. A valid (but wrong-context)
      # confirmation token can't be used to rotate a password — same uniform
      # error as an expired one.
      user = Emisar.Fixtures.user_fixture()
      confirm_token = Emisar.Auth.issue_confirmation_token!(user)

      {:ok, lv, _html} = live(conn, ~p"/reset_password/#{confirm_token}")

      result =
        lv
        |> form("#reset_form", %{
          "user" => %{
            "password" => "a-perfectly-long-password",
            "password_confirmation" => "a-perfectly-long-password"
          }
        })
        |> render_submit()

      # A successful reset push_navigates to /sign_in; a uniformly-invalid token
      # (reused, wrong-context, soft-deleted user) instead bounces back to
      # /reset_password — the destination is the cause-neutral tell.
      assert {:error, {:live_redirect, %{to: "/reset_password"}}} = result
    end

    test "a soft-deleted user can't reset their password", %{conn: conn} do
      # the reset token resolves to no LIVE user once the
      # row is soft-deleted, so the consume returns the same uniform invalid
      # error rather than rotating a tombstoned account's password.
      user = Emisar.Fixtures.user_fixture()
      token = Emisar.Auth.issue_password_reset_token!(user, [], %Emisar.RequestContext{})

      {:ok, _} = user |> Emisar.Users.User.Changeset.delete() |> Emisar.Repo.update()

      {:ok, lv, _html} = live(conn, ~p"/reset_password/#{token}")

      result =
        lv
        |> form("#reset_form", %{
          "user" => %{
            "password" => "a-perfectly-long-password",
            "password_confirmation" => "a-perfectly-long-password"
          }
        })
        |> render_submit()

      # A successful reset push_navigates to /sign_in; a uniformly-invalid token
      # (reused, wrong-context, soft-deleted user) instead bounces back to
      # /reset_password — the destination is the cause-neutral tell.
      assert {:error, {:live_redirect, %{to: "/reset_password"}}} = result
    end
  end
end
