defmodule EmisarWeb.MfaChallengeLiveTest do
  @moduledoc """
  The second-factor page between password and session: it must refuse
  to render without a live pending-MFA marker (no skipping the first
  factor by URL), and offer the lost-device recovery-code path.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Audit.Event
  alias Emisar.Auth

  @password "long-mfa-password-123"

  defp mfa_user! do
    {:ok, user} =
      Emisar.Users.register_user(%{
        email: "mfa-#{System.unique_integer([:positive])}@example.com",
        full_name: "MFA User",
        password: @password
      })

    user = Emisar.Fixtures.confirm_user(user)

    {:ok, account} =
      Emisar.Accounts.create_account_with_owner(
        %{name: "MFA Co", slug: "mfa-co-#{System.unique_integer([:positive])}"},
        user
      )

    secret = Auth.generate_mfa_secret()

    {user, _codes} =
      Emisar.Fixtures.enable_mfa!(secret, Emisar.Fixtures.subject_for(user, account))

    user
  end

  test "without a pending marker, bounces back to /sign_in", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/mfa")
  end

  test "an expired pending marker bounces back to /sign_in (refreshed an old tab)", %{conn: conn} do
    # `get_pending_mfa/1` treats a marker past its 5-min TTL
    # as absent (the `expires_at <= now` branch), so mounting the challenge with a
    # stashed user_id but a past `pending_mfa_expires_at` (the operator left the tab
    # open and refreshed) gets the same expired bounce as no marker at all — a stale
    # session can never drift into "no password needed".
    user = mfa_user!()

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:pending_mfa_user_id, user.id)
      |> Plug.Conn.put_session(
        :pending_mfa_expires_at,
        System.system_time(:second) - 1
      )

    assert {:error, {:live_redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/mfa")
  end

  test "the OTP input enforces a 6-digit numeric code (boundary)", %{conn: conn} do
    # the authenticator field bounds the code to exactly 6
    # numeric digits client-side (`minlength`/`maxlength` 6 + `pattern="[0-9]*"`),
    # matching the TOTP shape. (A 6-digit code's actual verification + finalize is
    # the happy path covered by auth_flow_test's "OTP against a valid marker".)
    user = mfa_user!()

    conn =
      post(conn, ~p"/sign_in", %{"user" => %{"email" => user.email, "password" => @password}})

    {:ok, _lv, html} = live(conn, ~p"/sign_in/mfa")

    assert html =~ ~s|minlength="6"|
    assert html =~ ~s|maxlength="6"|
    assert html =~ ~s|pattern="[0-9]*"|
  end

  test "renders the OTP form after the password step set the marker", %{conn: conn} do
    user = mfa_user!()

    conn =
      post(conn, ~p"/sign_in", %{"user" => %{"email" => user.email, "password" => @password}})

    assert redirected_to(conn) == ~p"/sign_in/mfa"

    {:ok, lv, html} = live(conn, ~p"/sign_in/mfa")
    assert html =~ "Two-factor authentication"
    # Body intro (the "to finish signing in" suffix distinguishes it from the
    # controller's pending-MFA flash, which shares the leading phrase).
    assert html =~ "authenticator app to finish signing in"
    # Every sibling auth form disables on submit; this one must too, or a
    # double-click burns the one-time code.
    assert html =~ "phx-disable-with"

    # The lost-device path swaps the OTP input AND the intro copy — the
    # "authenticator app" line shouldn't linger in recovery mode.
    recovery_html = render_click(lv, "toggle_recovery", %{})
    assert recovery_html =~ "one-time recovery codes"
    refute recovery_html =~ "authenticator app to finish signing in"

    # Terminal escape for "lost device AND codes" shows only on the recovery
    # path (no admin reset exists, so it honestly points to support@).
    refute html =~ "Lost your recovery codes too?"
    assert recovery_html =~ "Lost your recovery codes too?"
    assert recovery_html =~ "support@emisar.dev"
  end

  test "the MFA form posts only the second factor — never the password again", %{conn: conn} do
    # the password step already verified credentials and
    # stashed the pending marker, so the challenge form (`#mfa_form`) carries ONLY
    # the OTP/recovery field. The password is never re-sent: no password input
    # exists to capture or replay it, on either the authenticator or recovery view.
    user = mfa_user!()

    conn =
      post(conn, ~p"/sign_in", %{"user" => %{"email" => user.email, "password" => @password}})

    {:ok, lv, html} = live(conn, ~p"/sign_in/mfa")

    # Authenticator view: the OTP field is present, no password field.
    assert html =~ ~s|name="user[otp]"|
    refute html =~ ~s|type="password"|
    refute html =~ ~s|name="user[password]"|

    # The recovery view swaps in the recovery-code field — still no password.
    recovery_html = render_click(lv, "toggle_recovery", %{})
    assert recovery_html =~ ~s|name="user[recovery_code]"|
    refute recovery_html =~ ~s|type="password"|
    refute recovery_html =~ ~s|name="user[password]"|
  end

  test "a wrong recovery code is rejected and audited, the pending step re-stashed", %{
    conn: conn
  } do
    # the recovery toggle posts `user[recovery_code]` back to
    # POST /sign_in, which (holding the pending marker) runs
    # `Auth.consume_mfa_recovery_code`. An unknown code returns `{:error, :invalid}`:
    # the controller bounces back to /sign_in/mfa with "didn't match", consumes no
    # code, and writes a `user.mfa_failed` audit row with reason `invalid_recovery_code`.
    user = mfa_user!()

    # Password step stashes the pending-MFA marker.
    conn =
      post(conn, ~p"/sign_in", %{"user" => %{"email" => user.email, "password" => @password}})

    assert redirected_to(conn) == ~p"/sign_in/mfa"

    # The MFA form (recovery view) submits ONLY the recovery code — no password.
    conn =
      conn
      |> recycle()
      |> post(~p"/sign_in", %{"user" => %{"recovery_code" => "not-a-real-recovery-code"}})

    assert redirected_to(conn) == ~p"/sign_in/mfa"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't match"

    # Audited as an MFA failure with the recovery-specific reason — distinct from a
    # wrong TOTP (`invalid_otp`), so the audit stream tells them apart.
    failures =
      Event.Query.all()
      |> Event.Query.by_actor_id(user.id)
      |> Event.Query.by_event_type("user.mfa_failed")
      |> Emisar.Repo.all()

    assert Enum.any?(failures, &(&1.payload["reason"] == "invalid_recovery_code"))
  end
end
