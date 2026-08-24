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
  alias Emisar.{Auth, Repo, RequestContext, Throttle}
  alias Emisar.Auth.UserToken

  test "renders the email form that POSTs to the start action", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic")

    assert html =~ "one-time"
    assert html =~ ~s(action="/sign_in/magic/start")
    # Blank email is gated client-side (the flow has no server-side email error,
    # by anti-enumeration design) — the `required` attr is the only gate.
    assert html =~ ~r/<input[^>]*name="user\[email\]"[^>]*required/
  end

  test "?sent=1 shows the check-inbox panel + the 6-character code form", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{"magic_link_email" => "operator@example.test"})
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
    conn = Plug.Test.init_test_session(conn, %{"magic_link_email" => "operator@example.test"})
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

  test "?sent=1 with no stashed address falls back to the email form", %{conn: conn} do
    # A bookmark, a reload after the session lapsed, or a malformed POST: without
    # the stashed address there is no code to verify and no Resend to offer, so a
    # code form here could only ever fail.
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    assert html =~ ~s(action="/sign_in/magic/start")
    refute html =~ "Check your inbox."
    refute html =~ ~s(phx-hook="CodeInput")
  end

  test "?sent=1 with a stashed expiry renders the code countdown wired to the submit", %{
    conn: conn
  } do
    expires = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.to_iso8601()

    session = %{
      "magic_link_email" => "operator@example.test",
      "magic_link_expires_at" => expires
    }

    conn = Plug.Test.init_test_session(conn, session)
    {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

    # The countdown element carries the hook + the expiry, and targets both the
    # code submit and the boxes it disables on lapse.
    assert html =~ ~s(id="code-expiry")
    assert html =~ ~s(phx-hook="MagicCodeExpiry")
    assert html =~ ~s(data-disable="code-submit")
    assert html =~ ~s(data-disable-inputs="magic-code")
    assert html =~ ~s(id="code-submit")
  end

  describe "verifying the typed code (verify_code)" do
    setup %{conn: conn} do
      user = Fixtures.Users.create_user()

      assert {:ok, %{token_id: token_id, nonce: nonce}} =
               Auth.request_magic_link(user, %RequestContext{})

      # The raw secret only leaves Auth by email, so read the typed code back
      # out of the delivered message, as the operator does.
      assert_received {:email, sent}
      [_, secret] = Regex.run(~r"/sign_in/magic/[^/]+/([0-9A-Z]{6})", sent.text_body)

      conn =
        Plug.Test.init_test_session(conn, %{
          "magic_link_token_id" => token_id,
          "magic_link_nonce" => nonce,
          "magic_link_email" => user.email
        })

      %{conn: conn, user: user, token_id: token_id, secret: secret}
    end

    test "a wrong code shows an inline error and stays on the page (no redirect)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      html = render_hook(lv, "verify_code", %{"code" => "000000"})

      assert html =~ "match or has expired"
    end

    test "a rejected code clears the boxes so a correction can't resubmit itself", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      render_hook(lv, "verify_code", %{"code" => "000000"})

      assert_push_event(lv, "code:reset", %{id: "magic-code"})
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

    test "the signed LiveView session never carries the token id or nonce", %{
      conn: conn,
      token_id: token_id
    } do
      nonce = get_session(conn, :magic_link_nonce)
      response = get(conn, ~p"/sign_in/magic?sent=1")
      html = html_response(response, 200)
      assert [_, signed] = Regex.run(~r/data-phx-session="([^"]+)"/, html)

      salt = EmisarWeb.Endpoint.config(:live_view)[:signing_salt]

      assert {:ok, {6, %{session: exported}}} =
               Phoenix.Token.verify(EmisarWeb.Endpoint, salt, signed)

      refute Map.has_key?(exported, "magic_link_token_id")
      refute Map.has_key?(exported, "magic_link_nonce")
      refute inspect(exported) =~ token_id
      refute inspect(exported) =~ nonce
    end

    test "the socket IP cap rejects before touching even a correct factor", %{
      conn: conn,
      token_id: token_id,
      secret: secret
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      ip_address = EmisarWeb.RequestContext.from_conn(conn).ip_address

      for _ <- 1..30 do
        assert Throttle.check("magic_link_verify", ip_address, 30, 60_000) == :ok
      end

      {:ok, live, _html} = live(conn, ~p"/sign_in/magic?sent=1")
      assert render_hook(live, "verify_code", %{"code" => secret}) =~ "match or has expired"

      assert %UserToken{context: "magic_link", remaining_attempts: 5} =
               Repo.get!(UserToken, token_id)
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
