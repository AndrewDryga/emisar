defmodule EmisarWeb.UserSignInLiveTest do
  @moduledoc """
  The shared email+password sign-in page. It is a deliberately "dead"
  LiveView: the form posts to the `POST /sign_in` controller (the auth
  logic lives there), so the page only renders — it carries no
  `handle_event`. What matters here is that every sign-in path is offered
  and the form is wired to the controller.
  """
  use EmisarWeb.ConnCase, async: true

  test "the form renders with every sign-in path offered", %{conn: conn} do
    # closes AUTH-002-T01 — the password form posts to /sign_in (phx-update=ignore
    # so LiveView never reclaims the browser-managed inputs), and the page surfaces
    # the remember-me checkbox plus the forgot-password, magic-link and SSO routes.
    {:ok, _lv, html} = live(conn, ~p"/sign_in")

    assert html =~ ~s|id="login_form"|
    assert html =~ ~s|action="/sign_in"|
    assert html =~ ~s|phx-update="ignore"|

    # Remember-me (60-day token) checkbox.
    assert html =~ ~s|name="user[remember_me]"|

    # The three fallbacks beside the password path.
    assert html =~ ~p"/reset_password"
    assert html =~ ~p"/sign_in/magic"
    assert html =~ ~p"/sign_in/sso"

    # And the route to registration for a brand-new operator.
    assert html =~ ~p"/sign_up"
  end

  test "the email field is pre-filled from a failed-attempt flash", %{conn: conn} do
    # closes AUTH-002-T02 (LV side) — the controller stashes the typed email in an
    # `:email` flash on a failed POST; the LV reads it back into the form so the
    # operator doesn't retype it after a wrong password.
    conn = Phoenix.ConnTest.init_test_session(conn, %{})

    {:ok, _lv, html} =
      conn
      |> Plug.Conn.put_session(:phoenix_flash, %{"email" => "typed@example.com"})
      |> live(~p"/sign_in")

    assert html =~ ~s|value="typed@example.com"|
  end

  test "the page carries no client-side event handler — it's a controller-backed form", %{
    conn: conn
  } do
    # closes AUTH-002-T03 — the form is submitted server-side through the controller
    # (`action="/sign_in"` + `phx-update="ignore"`), not over the socket: the
    # `#login_form` binds no `phx-submit`/`phx-change`, so there is no live handler
    # to intercept or replay the credentials over the channel.
    {:ok, _lv, html} = live(conn, ~p"/sign_in")

    # Isolate the form's own opening tag — the page's flash-group hooks carry
    # phx-* attrs of their own, so a whole-page refute would be a false positive.
    [form_tag] = Regex.run(~r/<form[^>]*id="login_form"[^>]*>/, html)
    refute form_tag =~ "phx-submit"
    refute form_tag =~ "phx-change"
    assert form_tag =~ ~s|action="/sign_in"|
  end
end
