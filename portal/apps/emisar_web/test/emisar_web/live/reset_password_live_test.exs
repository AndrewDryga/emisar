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
end
