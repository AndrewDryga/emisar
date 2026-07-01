defmodule EmisarWeb.MagicLinkLiveTest do
  @moduledoc """
  Passwordless sign-in request page — now render-only. The split-code FLOW
  (issue the token, set the nonce cookie, verify both halves) lives in
  `UserSessionController` and is tested there; this LV just renders the email
  form (POSTs to `:magic_link_start`) and, on `?sent=1`, the 6-character code form.
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

  test "?sent=1 shows the check-inbox panel + the 6-character code form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ "Check your inbox."
    assert html =~ ~s(action="/sign_in/magic/code")
    # The per-character boxes (CodeInput hook) submit through one hidden field.
    assert html =~ ~s(phx-hook="CodeInput")
    assert html =~ ~r/<input[^>]*type="hidden"[^>]*name="code"/
  end

  test "the sent panel links back to a fresh email form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ "Use a different email"
  end

  test "?sent=1 inlines the stashed address and offers Resend", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"magic_link_email" => "operator@example.test"})
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    # The address is inlined into the sentence as <code>, with the space before
    # it and NO stray space before the period (the HEEx-whitespace gotcha).
    assert html =~ ~r{6-character code to <code[^>]*>operator@example\.test</code>\. Enter}
    # ...and the cooldown-gated resend button is present.
    assert html =~ ~s(id="resend-code")
    assert html =~ ~s(phx-hook="ResendCooldown")
  end

  test "?sent=1 with no stashed address shows neither the address nor Resend", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ "6-character code. Enter"
    refute html =~ ~s(id="resend-code")
  end

  test "?sent=1 with a stashed expiry renders the code countdown wired to the submit", %{
    conn: conn
  } do
    expires = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.to_iso8601()
    conn = Plug.Test.init_test_session(conn, %{"magic_link_expires_at" => expires})
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    # The countdown element carries the hook + the expiry, and targets the code
    # submit it disables on lapse.
    assert html =~ ~s(id="code-expiry")
    assert html =~ ~s(phx-hook="MagicCodeExpiry")
    assert html =~ ~s(data-disable="code-submit")
    assert html =~ ~s(id="code-submit")
  end
end
