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

    test "revoke_other_sessions with nothing to revoke says so", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_other_sessions", %{}) =~ "No other sessions to revoke."
    end

    test "revoking a vanished session id flashes instead of crashing", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_session", %{"id" => Ecto.UUID.generate()}) =~
               "Session no longer exists."
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

      html =
        lv
        |> form("#mfa_form", %{"mfa" => %{"otp" => NimbleTOTP.verification_code(secret)}})
        |> render_submit()

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

    test "regenerate + disable for an MFA-enabled user", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      secret = Auth.generate_mfa_secret()

      {:ok, _user, _codes} =
        Auth.enable_mfa(
          secret,
          NimbleTOTP.verification_code(secret),
          Emisar.Fixtures.subject_for(user, account)
        )

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
end
