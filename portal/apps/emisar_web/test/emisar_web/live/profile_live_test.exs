defmodule EmisarWeb.ProfileLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "email form validation" do
    test "a malformed email surfaces inline via phx-change, not a flash", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/settings/profile")

      # The email-format check is a field error driven by phx-change. On
      # submit the current-password challenge runs first, so the format
      # error has to show before the user ever fills that in.
      html =
        lv
        |> form("#email_form", %{
          "email" => %{"email" => "not-an-email", "current_password" => ""}
        })
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end
  end

  describe "password form validation" do
    test "a too-short new password renders inline, not in a flash", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/settings/profile")

      html =
        lv
        |> form("#password_form", %{
          "password" => %{
            "current_password" => "very-long-password-here",
            "password" => "short",
            "password_confirmation" => "short"
          }
        })
        |> render_submit()

      assert html =~ "should be at least 12 character"
      # Old flash copy is gone.
      refute html =~ "Use at least 12 characters."
    end

    test "a confirmation mismatch renders inline on the confirmation field, not in a flash", %{
      conn: conn
    } do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/settings/profile")

      html =
        lv
        |> form("#password_form", %{
          "password" => %{
            "current_password" => "very-long-password-here",
            "password" => "another-long-password",
            "password_confirmation" => "does-not-match-this-one"
          }
        })
        |> render_submit()

      assert html =~ "does not match password"
      refute html =~ "New passwords don&#39;t match."
    end
  end
end
