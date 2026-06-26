defmodule EmisarWeb.MagicLinkLiveTest do
  @moduledoc """
  Passwordless sign-in request page — now render-only. The split-code FLOW
  (issue the token, set the nonce cookie, verify both halves) lives in
  `UserSessionController` and is tested there; this LV just renders the email
  form (POSTs to `:magic_link_start`) and, on `?sent=1`, the 6-digit code form.
  """
  use EmisarWeb.ConnCase, async: true

  test "renders the email form that POSTs to the start action", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic")

    assert html =~ "one-time link"
    assert html =~ ~s(action="/sign_in/magic/start")
    # Blank email is gated client-side (the flow has no server-side email error,
    # by anti-enumeration design) — the `required` attr is the only gate.
    assert html =~ ~r/<input[^>]*name="user\[email\]"[^>]*required/
  end

  test "?sent=1 shows the check-inbox panel + the 6-digit code form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ "Check your inbox."
    assert html =~ ~s(action="/sign_in/magic/code")
    assert html =~ ~r/<input[^>]*name="code"[^>]*required/
  end

  test "the sent panel links back to a fresh email form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ "Use a different email"
  end
end
