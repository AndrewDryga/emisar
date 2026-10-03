defmodule EmisarWeb.MagicLinkLiveTest do
  @moduledoc """
  The "check your email" page every emailed code lands on: a workspace sign-in,
  an invitation, a sign-up. A controller started the request (issuing the code
  sets a nonce cookie a LiveView can't) and stashed it in the session; this page
  verifies the typed code itself (`verify_code`) — a wrong code shows inline, a
  match redirects to `:magic_link_complete` with a cookie-bound handoff. Without
  a pending request there is nothing to verify, so the page goes to `/sign_in`.
  Issuing, the emailed link and completion are `UserSessionController`'s.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Repo, RequestContext, Throttle}
  alias Emisar.Auth.UserToken
  alias EmisarWeb.MagicLinkHandoff

  defp pending_code do
    account = Fixtures.Accounts.create_account()
    member = Fixtures.Memberships.create_membership(account_id: account.id)

    assert {:ok, %{token_id: token_id, nonce: nonce}} =
             Auth.request_magic_link(account, member.email, %RequestContext{})

    # The code only leaves Auth by email, so read it back as the operator does.
    assert_received {:email, sent}
    [_, code] = Regex.run(~r"/sign_in/magic/[^/]+/([0-9A-Z]{6})", sent.text_body)

    %{account: account, member: member, token_id: token_id, nonce: nonce, code: code}
  end

  defp with_pending(conn, %{token_id: token_id, nonce: nonce, member: member} = pending) do
    session = %{
      "magic_link_token_id" => token_id,
      "magic_link_nonce" => nonce,
      "magic_link_email" => member.email,
      "magic_link_back_to" => ~p"/app/#{pending.account}/sign_in"
    }

    Plug.Test.init_test_session(conn, session)
  end

  describe "the sent page" do
    setup %{conn: conn} do
      pending = pending_code()
      %{conn: with_pending(conn, pending), pending: pending}
    end

    test "inlines the address and offers the code form and Resend", %{
      conn: conn,
      pending: pending
    } do
      {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

      assert html =~ "Check your inbox"
      # The address is inlined into the sentence as <code>, with the space before
      # it and NO stray space before the period (the HEEx-whitespace gotcha).
      escaped = Regex.escape(pending.member.email)
      assert html =~ ~r{6-character code to <code[^>]*>#{escaped}</code>\. Enter}
      # The code is verified in this LiveView; the CodeInput boxes aggregate into
      # one hidden field the phx-submit reads.
      assert html =~ ~s(phx-submit="verify_code")
      assert html =~ ~s(phx-hook="CodeInput")
      assert html =~ ~r/<input[^>]*type="hidden"[^>]*name="code"/
      # Resend re-issues whatever code this browser holds; the form carries nothing.
      assert html =~ ~s(action="/sign_in/magic/resend")
      assert html =~ ~s(id="resend-code")
      assert html =~ ~s(phx-hook="ResendCooldown")
    end

    test "links back to where the request began", %{conn: conn, pending: pending} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      assert has_element?(lv, ~s(a[href="#{~p"/app/#{pending.account}/sign_in"}"]), "Start again")
    end

    test "a stashed expiry renders the code countdown wired to the submit", %{conn: conn} do
      expires = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.to_iso8601()
      conn = Plug.Test.init_test_session(conn, %{"magic_link_expires_at" => expires})

      {:ok, _lv, html} = live(conn, ~p"/sign_in/magic?sent=1")

      assert html =~ ~s(id="code-expiry")
      assert html =~ ~s(phx-hook="MagicCodeExpiry")
      assert html =~ ~s(data-disable="code-submit")
      assert html =~ ~s(data-disable-inputs="magic-code")
      assert html =~ ~s(id="code-submit")
    end
  end

  test "without a pending request the page goes to /sign_in", %{conn: conn} do
    # A bookmark, a reload after the session lapsed, or only the address left:
    # there is no code to verify, so a code form here could only ever fail.
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/magic?sent=1")

    only_address = Plug.Test.init_test_session(conn, %{"magic_link_email" => "a@example.test"})
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(only_address, ~p"/sign_in/magic")
  end

  describe "verifying the typed code (verify_code)" do
    setup %{conn: conn} do
      pending = pending_code()
      %{conn: with_pending(conn, pending), pending: pending}
    end

    test "a wrong code shows an inline error, stays on the page and clears the boxes", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      html = render_hook(lv, "verify_code", %{"code" => "000000"})

      assert html =~ "match or has expired"
      assert_push_event(lv, "code:reset", %{id: "magic-code"})
    end

    test "the correct code redirects to the completion with a handoff for this Member and code",
         %{conn: conn, pending: pending} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")

      assert {:error, {:redirect, %{to: to}}} =
               render_hook(lv, "verify_code", %{"code" => String.downcase(pending.code)})

      %URI{path: "/sign_in/magic/complete", query: query} = URI.parse(to)
      %{"handoff" => handoff} = URI.decode_query(query)
      assert MagicLinkHandoff.verify(handoff) == {:ok, {pending.member.id, pending.token_id}}
    end

    test "the signed LiveView session never carries the token id or nonce", %{
      conn: conn,
      pending: pending
    } do
      html = conn |> get(~p"/sign_in/magic?sent=1") |> html_response(200)
      assert [_, signed] = Regex.run(~r/data-phx-session="([^"]+)"/, html)

      salt = EmisarWeb.Endpoint.config(:live_view)[:signing_salt]

      assert {:ok, {6, %{session: exported}}} =
               Phoenix.Token.verify(EmisarWeb.Endpoint, salt, signed)

      refute Map.has_key?(exported, "magic_link_token_id")
      refute Map.has_key?(exported, "magic_link_nonce")
      refute inspect(exported) =~ pending.token_id
      refute inspect(exported) =~ pending.nonce
    end

    test "the per-IP cap rejects before touching even a correct code, and says so", %{
      conn: conn,
      pending: pending
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      ip_address = EmisarWeb.RequestContext.from_conn(conn).ip_address

      for _ <- 1..30 do
        assert Throttle.check("magic_link_verify", ip_address, 30, 60_000) == :ok
      end

      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")
      html = render_hook(lv, "verify_code", %{"code" => pending.code})

      # The code was correct — telling the operator it wasn't sends them to
      # Resend, which spends the separate send budget on a live code.
      assert html =~ "Too many attempts"
      refute html =~ "match or has expired"

      assert %UserToken{context: "magic_link", remaining_attempts: 5} =
               UserToken.Query.by_id(pending.token_id) |> Repo.one()
    end

    test "a sign-up code hands off with no Member yet", %{conn: conn} do
      email = "founder-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %{token_id: token_id, nonce: nonce}} =
               Auth.request_sign_up_code(
                 %{"email" => email, "account_name" => "Handoff Co"},
                 %RequestContext{}
               )

      assert_received {:email, sent}
      [_, code] = Regex.run(~r"/sign_in/magic/[^/]+/([0-9A-Z]{6})", sent.text_body)

      conn =
        Plug.Test.init_test_session(conn, %{
          "magic_link_token_id" => token_id,
          "magic_link_nonce" => nonce
        })

      {:ok, lv, _html} = live(conn, ~p"/sign_in/magic?sent=1")
      assert {:error, {:redirect, %{to: to}}} = render_hook(lv, "verify_code", %{"code" => code})

      %{"handoff" => handoff} = to |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert MagicLinkHandoff.verify(handoff) == {:ok, {nil, token_id}}
    end
  end
end
