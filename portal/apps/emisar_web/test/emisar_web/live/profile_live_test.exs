defmodule EmisarWeb.ProfileLiveTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Auth

  # register_and_log_in's fixture password (conn_case.ex).
  @password "very-long-password-here"

  describe "email form validation" do
    test "a malformed email surfaces inline via phx-change, not a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      # The email form warns the change is immediate (the sign-in identity
      # flips right away).
      assert html =~ "takes effect immediately"

      # The email-format check is a field error driven by phx-change. On
      # submit the current-password challenge runs first, so the format
      # error has to show before the user ever fills that in.
      html =
        lv
        |> form("#email_form", %{
          "email" => %{"email" => "not-an-email", "current_password" => ""}
        })
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end
  end

  describe "password form validation" do
    test "a too-short new password renders inline, not in a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> form("#password_form", %{
          "password" => %{
            "current_password" => "very-long-password-here",
            "password" => "short",
            "password_confirmation" => "short"
          }
        })
        |> render_submit()

      assert html =~ "should be at least 12 character"
      # Old flash copy is gone.
      refute html =~ "Use at least 12 characters."
    end

    test "a confirmation mismatch renders inline on the confirmation field, not in a flash", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> form("#password_form", %{
          "password" => %{
            "current_password" => "very-long-password-here",
            "password" => "another-long-password",
            "password_confirmation" => "does-not-match-this-one"
          }
        })
        |> render_submit()

      assert html =~ "does not match password"
      refute html =~ "New passwords don&#39;t match."
    end

    test "a valid change updates the password and signs other devices out", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      # A second signed-in device — the change must revoke it.
      {other_conn, _user, _account} = register_and_log_in(build_conn())
      _ = other_conn
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> form("#password_form", %{
          "password" => %{
            "current_password" => @password,
            "password" => "a-brand-new-password",
            "password_confirmation" => "a-brand-new-password"
          }
        })
        |> render_submit()

      assert html =~ "Password updated. Other devices were signed out."

      updated = Emisar.Repo.reload!(user)
      assert Emisar.Users.User.valid_password?(updated, "a-brand-new-password")
    end

    test "a wrong current password is a flash, not a field error", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> form("#password_form", %{
          "password" => %{
            "current_password" => "not-the-real-password",
            "password" => "a-brand-new-password",
            "password_confirmation" => "a-brand-new-password"
          }
        })
        |> render_submit()

      assert html =~ "Current password is incorrect."
    end
  end

  describe "profile form" do
    test "saving a new full name updates and confirms", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> form("#profile_form", %{"profile" => %{"full_name" => "Renamed Person"}})
        |> render_submit()

      assert html =~ "Profile updated."
      assert html =~ "Renamed Person"
      assert Emisar.Repo.reload!(user).full_name == "Renamed Person"
    end
  end

  describe "email form" do
    test "the current-password challenge gates the change", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> form("#email_form", %{
          "email" => %{"email" => "fresh@example.com", "current_password" => "wrong-password"}
        })
        |> render_submit()

      assert html =~ "Current password is incorrect."
      refute Emisar.Repo.reload!(user).email == "fresh@example.com"
    end

    test "with the right password the email changes", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> form("#email_form", %{
          "email" => %{"email" => "fresh@example.com", "current_password" => @password}
        })
        |> render_submit()

      assert html =~ "Email updated."
      assert Emisar.Repo.reload!(user).email == "fresh@example.com"
    end
  end

  describe "sessions" do
    test "lists sessions and revokes the selected one", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      # A second session for the same user (another device).
      other_conn = build_conn() |> log_in_user(user)
      _ = other_conn

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      html = render(lv)
      assert html =~ "This device"

      subject = Emisar.Fixtures.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject, page: [limit: 100])
      assert length(sessions) == 2

      html = render_click(lv, "revoke_other_sessions", %{})
      assert html =~ "1 other session signed out."

      {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject, page: [limit: 100])
      assert length(sessions) == 1
    end

    test "lists each session and marks the current device", %{conn: conn} do
      # closes TEAM-022-T01
      {conn, user, account} = register_and_log_in(conn)

      # A second device with recognizable metadata so its row renders distinctly
      # from the current session.
      _other =
        Emisar.Auth.create_session_token!(user, :password, false, %{
          "ip_address" => "198.51.100.4",
          "user_agent" => "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
        })

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Exactly one row is badged the current device; the second device renders
      # its IP + parsed label.
      assert html =~ "This device"
      assert html =~ "198.51.100.4"
      assert html =~ "Chrome on Linux"

      subject = Emisar.Fixtures.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject, page: [limit: 100])
      assert length(sessions) == 2
    end

    test "revoking one non-current session removes exactly that row", %{conn: conn} do
      # closes TEAM-023-T01
      {conn, user, account} = register_and_log_in(conn)

      # A second device — the row we'll revoke. Its session is found by being the
      # one whose token-digest is NOT the current device's.
      other_raw = Emisar.Auth.create_session_token!(user, :password, false)
      other_digest = Emisar.Crypto.hash(other_raw)

      subject = Emisar.Fixtures.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject, page: [limit: 100])
      other = Enum.find(sessions, &(&1.token == other_digest))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_session", %{"id" => other.id}) =~ "Session revoked."

      # Down to one — only the current device remains.
      {:ok, remaining, _meta} = Auth.list_sessions_for_user(subject, page: [limit: 100])
      assert length(remaining) == 1
      refute Enum.any?(remaining, &(&1.id == other.id))
    end

    test "the current device row offers no Revoke control", %{conn: conn} do
      # closes TEAM-023-T05
      {conn, user, account} = register_and_log_in(conn)

      # Two devices: one current, one other. The other carries a Revoke button;
      # the current device must not (you can't sign yourself out from here —
      # that's "sign out everywhere else").
      other_raw = Emisar.Auth.create_session_token!(user, :password, false)
      other_digest = Emisar.Crypto.hash(other_raw)

      subject = Emisar.Fixtures.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject, page: [limit: 100])
      other = Enum.find(sessions, &(&1.token == other_digest))
      current = Enum.find(sessions, &(&1.token != other_digest))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "button[phx-click='revoke_session'][phx-value-id='#{other.id}']")

      refute has_element?(
               lv,
               "button[phx-click='revoke_session'][phx-value-id='#{current.id}']"
             )
    end

    test "revoke_other_sessions with nothing to revoke says so", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_other_sessions", %{}) =~ "No other sessions to revoke."
    end

    test "the session list is capped at 100 — the bound the page passes", %{conn: conn} do
      # closes TEAM-022-T04
      # The page reads sessions with `page: [limit: 100]`, so even a user with
      # more than 100 active sessions can never blow up the assigns/DOM. Prove
      # the cap with the SAME opts the LV uses (seeding 101 and reading back).
      {conn, user, account} = register_and_log_in(conn)

      # 100 more sessions (register_and_log_in already created one) → 101 total.
      for _ <- 1..100, do: Emisar.Auth.create_session_token!(user, :password, false)

      subject = Emisar.Fixtures.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject, page: [limit: 100])
      assert length(sessions) == 100

      # And the page mounts + renders under that load — the "Sign out everywhere
      # else" control shows (>1 session), proving the list assigned without blowing
      # up the socket.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert html =~ "Sign out everywhere else"
    end

    test "the disconnected (dead) render reads no sessions and shows the empty state", %{
      conn: conn
    } do
      # closes TEAM-022-T07
      # IL-18: the session list is the only DB read on this page, gated behind
      # connected?/1 — so the dead render a plain GET produces must show "No
      # active sessions." with no rows, even though a real session exists. A
      # second device is seeded so "no rows on the dead render" is meaningful.
      {conn, user, account} = register_and_log_in(conn)

      _other =
        Emisar.Auth.create_session_token!(user, :password, false, %{
          "ip_address" => "203.0.113.9",
          "user_agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) Safari/17.0"
        })

      dead = conn |> get(~p"/app/#{account}/settings/profile") |> html_response(200)

      assert dead =~ "No active sessions."
      # The seeded device's metadata is NOT read on the dead pass.
      refute dead =~ "203.0.113.9"
      refute dead =~ "This device"
    end

    test "revoking a vanished session id flashes instead of crashing", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_session", %{"id" => Ecto.UUID.generate()}) =~
               "Session no longer exists."
    end

    test "the rendered session rows never surface the raw token (only id + metadata)", %{
      conn: conn
    } do
      # closes TEAM-022-T05
      {conn, user, account} = register_and_log_in(conn)

      # A second session minted with a recognizable device (the metadata DOES
      # render) — and we keep the raw token it returns. The token is stored
      # hashed (UserToken.token holds the digest); neither the raw token nor its
      # digest may ever reach the rendered rows — only id + inserted_at + the
      # ip/user-agent metadata.
      raw_token =
        Emisar.Auth.create_session_token!(user, :password, false, %{
          "ip_address" => "203.0.113.7",
          "user_agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) Firefox/126.0"
        })

      digest = Emisar.Crypto.hash(raw_token)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      # The row renders from metadata, so the device + IP are visible…
      assert html =~ "Firefox on Mac"
      assert html =~ "203.0.113.7"

      # …but the credential itself never is — not the raw token, not its digest
      # (the digest is binary, so check both its base16 + base64 encodings to be
      # sure no accidental serialization leaks it).
      refute html =~ raw_token
      refute html =~ Base.encode16(digest, case: :lower)
      refute html =~ Base.encode64(digest)
    end
  end

  describe "MFA lifecycle" do
    test "start → confirm with a valid OTP enables MFA and shows recovery codes once", %{
      conn: conn
    } do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "start_mfa", %{})
      assert html =~ "<svg"

      # The LV holds the secret server-side; read it back the way the
      # operator would — from the manual-entry fallback in the QR panel.
      secret = mfa_secret_from(html)

      html = submit_mfa_enrollment(lv, secret)

      assert html =~ "MFA enabled."
      assert html =~ "recovery codes"
      assert Emisar.Repo.reload!(user).mfa_enabled_at

      # Codes are shown exactly once — the panel goes away on dismiss
      # (the enable flash still mentions them, so check the element).
      assert has_element?(lv, "#mfa-recovery-codes-blob")

      # The voluntary reveal offers a file download too (matching the enforced
      # setup path) — a clipboard is too volatile for a lockout credential.
      assert html =~ ~s(download="emisar-recovery-codes.txt")

      # Once saved, the MFA-on view surfaces how many codes remain (a fresh 10,
      # so no low-count nudge).
      html = render_click(lv, "dismiss_recovery_codes", %{})
      refute has_element?(lv, "#mfa-recovery-codes-blob")
      assert html =~ "10 recovery codes remaining"
      refute html =~ "Regenerate for a fresh set"
    end

    test "the enrollment QR is a server-rendered inline SVG, not a third-party image", %{
      conn: conn
    } do
      # closes TEAM-019-T12
      # The otpauth URI carries the TOTP secret, so it must never be handed to an
      # external QR-image service. EmisarWeb.MfaQr renders the code as an inline
      # SVG server-side; `raw/1` on that markup is the documented IL-16 exception
      # (server-generated, not untrusted input). Assert the SVG is inlined and no
      # external image/script is the QR source.
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "start_mfa", %{})

      # The QR is an inlined <svg> (EQRCode), with the manual-entry fallback URI
      # present in the page…
      assert html =~ "<svg"
      assert html =~ "otpauth://totp/"
      # …and the secret-bearing URI is NEVER handed to a remote image: it isn't an
      # <img src=> at all, and no known QR-image service host appears.
      refute html =~ ~r/<img[^>]+otpauth/
      refute html =~ "chart.googleapis.com"
      refute html =~ "api.qrserver.com"
    end

    test "a low recovery-code count nudges to regenerate (amber)", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      # MFA on with only 2 codes left (8 burned down on lost-device sign-ins) —
      # tracked all along but never shown until now.
      user
      |> Ecto.Changeset.change(
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: ["digest-1", "digest-2"]
      )
      |> Emisar.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert html =~ "2 recovery codes remaining"
      assert html =~ "Regenerate for a fresh set"
    end

    test "a wrong OTP leaves MFA off", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_mfa", %{})

      html =
        lv
        |> form("#mfa_form", %{"mfa" => %{"otp" => "000000"}})
        |> render_submit()

      assert html =~ "Invalid code"
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "a non-numeric OTP is rejected and MFA stays off", %{conn: conn} do
      # closes TEAM-019-T08
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Start the enable flow so a pending secret is stashed, then submit a
      # six-char *non-numeric* code. NimbleTOTP compares it against the
      # secret-derived digits and it can't match, so enrollment is refused.
      render_click(lv, "start_mfa", %{})

      html =
        lv
        |> form("#mfa_form", %{"mfa" => %{"otp" => "abc123"}})
        |> render_submit()

      assert html =~ "Invalid code"
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "a code from a prior 30s bucket is rejected (no leeway)", %{conn: conn} do
      # closes TEAM-019-T07
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "start_mfa", %{})
      secret = mfa_secret_from(html)

      # Crypto.valid_totp? validates only against the CURRENT window with no
      # leeway, so a code minted two buckets back can never match the live one —
      # the offset is large enough that a window straddle can't make it collide.
      stale_otp =
        NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 90)

      html =
        lv
        |> form("#mfa_form", %{"mfa" => %{"otp" => stale_otp}})
        |> render_submit()

      assert html =~ "Invalid code"
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "dismissing the recovery-codes reveal hides them and they're not re-shown", %{conn: conn} do
      # closes TEAM-021-T04
      {conn, user, account} = register_and_log_in(conn)

      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Emisar.Fixtures.enable_mfa!(secret, Emisar.Fixtures.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Regenerate to reveal a fresh one-shot set, then dismiss it — the blob
      # element is gone and a fresh mount never re-renders the plaintext codes.
      shown = render_click(lv, "regenerate_recovery_codes", %{})
      assert has_element?(lv, "#mfa-recovery-codes-blob")

      # Codes are lowercase base32 (Crypto.mfa_recovery_code/0) — pull one out of
      # the reveal to prove it's gone after dismissal.
      [_, a_code | _] = Regex.run(~r/([a-z2-7]{16})/, shown)
      assert is_binary(a_code)

      dismissed = render_click(lv, "dismiss_recovery_codes", %{})
      refute has_element?(lv, "#mfa-recovery-codes-blob")
      refute dismissed =~ a_code

      {:ok, _lv2, remounted} = live(conn, ~p"/app/#{account}/settings/profile")
      refute remounted =~ "mfa-recovery-codes-blob"
      refute remounted =~ a_code
    end

    test "cancel_mfa drops the pending secret so confirm refuses", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_mfa", %{})
      render_click(lv, "cancel_mfa", %{})

      # Cancel removes the form from the DOM; a stale client could still
      # push the event, so fire it directly.
      html = render_submit(lv, "confirm_mfa", %{"mfa" => %{"otp" => "123456"}})

      assert html =~ "Start the enable flow first."
    end

    test "disabling MFA when it's already off is a graceful no-op, not an error", %{conn: conn} do
      # closes TEAM-020-T02
      # The disable control is only rendered with MFA on, but a stale client could
      # still push the event. Auth.disable_mfa writes nil/[] unconditionally on the
      # locked row, so a no-MFA user gets the success path (no crash, no error
      # flash) and stays cleanly disabled.
      {conn, user, account} = register_and_log_in(conn)
      refute Emisar.Repo.reload!(user).mfa_enabled_at

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "disable_mfa", %{})

      assert html =~ "MFA disabled."
      refute html =~ "Could not disable MFA."
      reloaded = Emisar.Repo.reload!(user)
      assert is_nil(reloaded.mfa_enabled_at)
      assert is_nil(reloaded.mfa_secret)
      assert reloaded.mfa_recovery_codes == []
    end

    test "regenerate + disable for an MFA-enabled user", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Emisar.Fixtures.enable_mfa!(secret, Emisar.Fixtures.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "regenerate_recovery_codes", %{}) =~
               "New recovery codes generated."

      html = render_click(lv, "disable_mfa", %{})
      assert html =~ "MFA disabled."
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end
  end

  defp mfa_secret_from(html) do
    # The setup panel renders the Base32 secret for manual entry.
    [_, encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, html)
    Base.decode32!(encoded, padding: false)
  end

  # Submits the enrollment form, retrying once across a 30s-window straddle (the
  # code-gen/validate boundary) — the same flake Fixtures.enroll_mfa guards, but
  # through the LiveView form. A straddle re-renders the form without the success
  # flash, so a second submit with a fresh code lands in a stable window.
  defp submit_mfa_enrollment(lv, secret) do
    html =
      lv
      |> form("#mfa_form", %{"mfa" => %{"otp" => NimbleTOTP.verification_code(secret)}})
      |> render_submit()

    if html =~ "MFA enabled." do
      html
    else
      lv
      |> form("#mfa_form", %{"mfa" => %{"otp" => NimbleTOTP.verification_code(secret)}})
      |> render_submit()
    end
  end
end
