defmodule EmisarWeb.MfaChallengeLiveTest do
  @moduledoc """
  The second-factor challenge after an emailed code verifies factor one. The
  partial-auth marker (`:mfa_pending_membership_id`) names the Member but grants
  nothing; only a correct TOTP or recovery code redirects to `:mfa_complete`
  with the handoff the controller trades for the session cookie.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Fixtures}
  alias EmisarWeb.MfaChallengeHandoff

  setup %{conn: conn} do
    {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
    secret = Auth.generate_mfa_secret()
    {member, recovery_codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

    conn =
      Plug.Test.init_test_session(conn, %{
        "mfa_pending_membership_id" => member.id,
        "mfa_pending_at" => System.system_time(:second)
      })

    %{conn: conn, member: member, secret: secret, recovery_codes: recovery_codes}
  end

  describe "mount" do
    test "no pending marker, or a stale one, redirects to the sign-in start", %{member: member} do
      conn = Plug.Test.init_test_session(build_conn(), %{})
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/mfa")

      stale =
        Plug.Test.init_test_session(build_conn(), %{
          "mfa_pending_membership_id" => member.id,
          "mfa_pending_at" => System.system_time(:second) - 601
        })

      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(stale, ~p"/sign_in/mfa")
    end

    test "a pending session renders the authenticator prompt", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in/mfa")

      assert html =~ "authenticator app"
      assert html =~ "Multi-factor authentication"
    end
  end

  describe "TOTP verification" do
    test "a correct code redirects to completion with a proof for this Member", %{
      conn: conn,
      member: member,
      secret: secret
    } do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")

      assert {:error, {:redirect, %{to: to}}} =
               render_hook(lv, "verify_totp", %{"otp" => Fixtures.Auth.totp_code(secret)})

      %URI{path: "/sign_in/mfa/complete", query: query} = URI.parse(to)
      %{"handoff" => handoff} = URI.decode_query(query)
      assert {:ok, proof} = MfaChallengeHandoff.verify(handoff)
      assert Auth.mfa_proof_membership_id(proof) == member.id
    end

    test "a wrong code shows an inline error and stays put", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")

      html = render_hook(lv, "verify_totp", %{"otp" => "000000"})

      assert html =~ "didn&#39;t match"
      # The boxes clear for the retry, like every other code screen.
      assert_push_event(lv, "code:reset", %{id: "mfa-otp"})
    end
  end

  describe "recovery-code verification" do
    test "an attempt expiring after mount does not consume the recovery code", %{
      conn: conn,
      member: member,
      recovery_codes: [code | _]
    } do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")
      lv |> element("button", "Use a recovery code") |> render_click()

      :sys.replace_state(
        lv.pid,
        &put_in(&1.socket.assigns.pending_at, System.system_time(:second) - 601)
      )

      result = lv |> form("form[phx-submit=verify_recovery]", %{code: code}) |> render_submit()

      assert {:error, {:redirect, %{to: "/sign_in", flash: flash}}} = result
      assert Phoenix.Flash.get(flash_map(flash), :error) =~ "Your sign-in attempt expired"
      assert {:ok, _proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, code})
    end

    test "a valid recovery code redirects to completion", %{
      conn: conn,
      recovery_codes: [code | _]
    } do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")
      render_click(lv, "use_recovery")

      assert {:error, {:redirect, %{to: to}}} =
               render_hook(lv, "verify_recovery", %{"code" => code})

      assert to =~ "/sign_in/mfa/complete?handoff="
    end

    test "a wrong recovery code shows an inline error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")
      render_click(lv, "use_recovery")

      html = render_hook(lv, "verify_recovery", %{"code" => "not-a-real-code"})

      assert html =~ "didn&#39;t match or has already been used"
    end
  end

  describe "brute-force cap" do
    test "repeated wrong codes are throttled — not an endless guessing oracle", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")

      # Exhaust the 5-attempt window (keyed by Member, so a page reload couldn't
      # reset it), then the next attempt is capped rather than probed again.
      for _ <- 1..5, do: render_hook(lv, "verify_totp", %{"otp" => "000000"})
      html = render_hook(lv, "verify_totp", %{"otp" => "000000"})

      assert html =~ "Too many attempts. Wait a few minutes, then try again."
    end
  end

  describe "factor toggle" do
    test "switches between the authenticator and recovery-code entry", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_in/mfa")
      assert html =~ "authenticator app"

      # Click the rendered switch-line control (the shared auth_footer_link in its
      # phx-click mode), not the event by name, so the toggle stays a real button.
      html = lv |> element("button", "Use a recovery code") |> render_click()
      assert html =~ "recovery codes"

      html = lv |> element("button", "Enter a code instead") |> render_click()
      assert html =~ "authenticator app"
    end
  end

  defp flash_map(token), do: Phoenix.LiveView.Utils.verify_flash(EmisarWeb.Endpoint, token)
end
