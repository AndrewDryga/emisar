defmodule EmisarWeb.UserSignInLiveTest do
  @moduledoc """
  The passwordless sign-in page. A deliberately "dead" LiveView: the email
  form POSTs to the `:magic_link_start` controller (which issues the split-code
  link), so the page only renders — it carries no `handle_event`. What matters
  here is that the magic-link and SSO paths are offered and the form is wired
  to the controller.
  """
  use EmisarWeb.ConnCase, async: true

  test "the form renders the magic-link and SSO paths", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in")

    assert html =~ "Welcome back"
    # The email form POSTs to the split-code magic-link start action.
    assert html =~ ~s|action="/sign_in/magic/start"|
    assert html =~ ~s|name="user[email]"|

    # SSO is offered beside the email path.
    assert html =~ ~p"/sign_in/sso"

    # And the route to registration for a brand-new operator.
    assert html =~ ~p"/sign_up"

    # Passwordless: no password field, no remember-me, no forgot-password link.
    refute html =~ ~s|name="user[password]"|
    refute html =~ ~s|name="user[remember_me]"|
    refute html =~ "reset_password"
  end

  test "the page carries no client-side event handler — it's a controller-backed form", %{
    conn: conn
  } do
    # The email form is submitted server-side through the controller
    # (`action="/sign_in/magic/start"`), not over the socket: it binds no
    # `phx-submit`/`phx-change`, so there is no live handler to intercept the email.
    {:ok, _lv, html} = live(conn, ~p"/sign_in")

    [form_tag] = Regex.run(~r/<form[^>]*action="\/sign_in\/magic\/start"[^>]*>/, html)
    refute form_tag =~ "phx-submit"
    refute form_tag =~ "phx-change"
  end
end
