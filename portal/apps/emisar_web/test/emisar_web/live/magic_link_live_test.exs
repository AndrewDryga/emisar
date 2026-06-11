defmodule EmisarWeb.MagicLinkLiveTest do
  @moduledoc """
  Passwordless sign-in request page. The load-bearing behavior is
  anti-enumeration: a known and an unknown email get the exact same
  "check your inbox" response.
  """
  use EmisarWeb.ConnCase, async: true

  test "renders the email form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic")

    assert html =~ "one-time link"
    assert html =~ "magic_link_form"
  end

  test "a registered email gets the sent panel", %{conn: conn} do
    user = Emisar.Fixtures.user_fixture()

    {:ok, lv, _html} = live(conn, ~p"/sign_in/magic")

    html =
      lv
      |> form("#magic_link_form", %{"user" => %{"email" => user.email}})
      |> render_submit()

    assert html =~ "Check your inbox."
    assert html =~ user.email
  end

  test "an unknown email gets the IDENTICAL sent panel (no enumeration)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_in/magic")

    html =
      lv
      |> form("#magic_link_form", %{"user" => %{"email" => "nobody@example.com"}})
      |> render_submit()

    assert html =~ "Check your inbox."
    assert html =~ "nobody@example.com"
  end

  test "reset_form returns to the email form", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_in/magic")

    lv
    |> form("#magic_link_form", %{"user" => %{"email" => "someone@example.com"}})
    |> render_submit()

    html = render_click(lv, "reset_form", %{})
    assert html =~ "magic_link_form"
    refute html =~ "Check your inbox."
  end
end
