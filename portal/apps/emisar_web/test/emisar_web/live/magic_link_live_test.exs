defmodule EmisarWeb.MagicLinkLiveTest do
  @moduledoc """
  Passwordless sign-in request page. The email form POSTs to `:magic_link_start`
  (a controller — it sets the nonce cookie a LiveView can't). On `?sent=1` this LV
  renders the 6-character code form AND verifies the typed code itself
  (`verify_code`): a wrong code shows inline with no reload; a match redirects to
  `:magic_link_complete` with a handoff. Token issuance + the email-link + handoff
  completion live in `UserSessionController` and are tested there.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth
  alias EmisarWeb.RegistrationHandoff

  test "renders the email form that POSTs to the start action", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic")

    assert html =~ "one-time"
    assert html =~ ~s(action="/sign_in/magic/start")
    # Blank email is gated client-side (the flow has no server-side email error,
    # by anti-enumeration design) — the `required` attr is the only gate.
    assert html =~ ~r/<input[^>]*name="user\[email\]"[^>]*required/
  end

  test "?sent=1 shows the check-inbox panel + the 6-character code form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ "Check your inbox."
    # The code is verified in this LiveView (no controller POST) — so a wrong code
    # can be shown inline; the per-character boxes (CodeInput hook) aggregate into
    # one hidden field the phx-submit reads.
    assert html =~ ~s(phx-submit="verify_code")
    assert html =~ ~s(phx-hook="CodeInput")
    assert html =~ ~r/<input[^>]*type="hidden"[^>]*name="code"/
  end

  test "the sent panel links back to a fresh email form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ "Use a different email"
  end

  test "a sent signup can correct the pending email in place", %{conn: conn} do
    conn =
      Plug.Test.init_test_session(conn, %{
        "magic_link_email" => "typo@example.test",
        "magic_link_registered" => true
      })

    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ ~s(action="/sign_up/email")
    assert html =~ "Send code to this email"
    refute html =~ "Use a different email"
  end

  test "a sent signup resend preserves the signed registration handoff", %{conn: conn} do
    user_id = Emisar.Repo.generate_id()

    conn =
      Plug.Test.init_test_session(conn, %{
        "magic_link_email" => "typo@example.test",
        "magic_link_registered" => true,
        "magic_link_registration_user_id" => user_id
      })

    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert [_, handoff] = Regex.run(~r/name="registration_handoff"[^>]*value="([^"]+)"/, html)
    assert RegistrationHandoff.verify(handoff) == {:ok, user_id}
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

  describe "verifying the typed code (verify_code)" do
    setup %{conn: conn} do
      user = Fixtures.Users.create_user()
      {token_id, nonce, secret} = Auth.issue_magic_link(user)

      conn =
        Plug.Test.init_test_session(conn, %{
          "magic_link_token_id" => token_id,
          "magic_link_nonce" => nonce,
          "magic_link_email" => user.email
        })

      %{conn: conn, user: user, secret: secret}
    end

    test "a wrong code shows an inline error and stays on the page (no redirect)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      html = render_hook(lv, "verify_code", %{"code" => "000000"})

      assert html =~ "match or has expired"
    end

    test "the correct code redirects to the cookie-bound sign-in completion", %{
      conn: conn,
      secret: secret
    } do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      assert {:error, {:redirect, %{to: to}}} =
               render_hook(lv, "verify_code", %{"code" => secret})

      assert to =~ "/sign_in/magic/complete?handoff="
    end

    test "a code with no token in the session (direct nav / unknown email) is refused inline", %{
      conn: conn
    } do
      conn = Plug.Test.init_test_session(conn, %{"magic_link_email" => "someone@example.test"})
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      html = render_hook(lv, "verify_code", %{"code" => "ABC123"})

      assert html =~ "match or has expired"
    end
  end
end
