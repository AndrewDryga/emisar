defmodule EmisarWeb.ProfileLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth

  describe "email form validation" do
    test "a profile without an email address does not claim confirmation is pending", %{
      conn: conn
    } do
      user = Fixtures.Users.create_sso_user(full_name: "No Email")
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "viewer"
      )

      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert has_element?(lv, "#email", "No email address")
      assert has_element?(lv, "#email", "Ask your workspace administrator")
      refute has_element?(lv, "#email", "Awaiting confirmation")
      assert has_element?(lv, "#change-email[disabled]")

      render_click(lv, "edit_email", %{})
      render_submit(lv, "save_email", %{"email" => %{"email" => "new@example.com"}})

      assert has_element?(lv, "#email_form", "Your profile has no email address")
      refute has_element?(lv, "#email_step_form")
      refute_received {:email, _}
    end

    test "a missing-email profile with MFA can add an address through its authenticator", %{
      conn: conn
    } do
      user =
        Fixtures.Users.create_sso_user()
        |> Fixtures.Users.set_mfa_state(
          mfa_secret: Auth.generate_mfa_secret(),
          mfa_enabled_at: DateTime.utc_now()
        )

      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/app/#{account}/settings/profile")

      refute has_element?(lv, "#change-email[disabled]")
      refute has_element?(lv, "#email", "Ask your workspace administrator")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "new@example.com"}})
      |> render_submit()

      assert has_element?(lv, "#email_step_form", "authenticator")
      assert is_nil(Emisar.Repo.reload!(user).email)
      refute_received {:email, _}
    end

    test "a malformed email surfaces inline via phx-change, not a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert html =~ "Personal details"
      refute has_element?(lv, "#email_form")
      assert has_element?(lv, "#change-email", "Change email")

      # The email-format check is a field error driven by phx-change.
      html =
        lv
        |> edit_email()
        |> form("#email_form", %{"email" => %{"email" => "not-an-email"}})
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end
  end

  describe "profile form" do
    test "the name saves independently and an unchanged value disables Save", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      refute has_element?(lv, "#profile_form")
      assert has_element?(lv, "#display-name", user.full_name)
      lv |> element("#change-name", "Change name") |> render_click()
      assert has_element?(lv, "#profile_form button[disabled]", "Save")
      refute has_element?(lv, "#email_form")

      lv
      |> form("#profile_form", %{"profile" => %{"full_name" => "Updated name"}})
      |> render_change()

      refute has_element?(lv, "#profile_form button[disabled]")

      lv
      |> form("#profile_form", %{"profile" => %{"full_name" => user.full_name}})
      |> render_change()

      assert has_element?(lv, "#profile_form button[disabled]", "Save")
    end

    test "saving a new full name updates and confirms", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      lv |> element("#change-name") |> render_click()

      html =
        lv
        |> form("#profile_form", %{"profile" => %{"full_name" => "Renamed Person"}})
        |> render_submit()

      assert html =~ "Name updated."
      assert html =~ "Renamed Person"
      assert Emisar.Repo.reload!(user).full_name == "Renamed Person"
      refute has_element?(lv, "#profile_form")
      assert has_element?(lv, "#change-name")
      refute has_element?(lv, "#email_form")
    end

    test "cancel discards the name draft without resetting an email edit", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      edit_email(lv)
      lv |> element("#change-name") |> render_click()
      lv |> form("#profile_form", profile: %{full_name: "Discard this"}) |> render_change()
      lv |> element("#profile_form button", "Cancel") |> render_click()

      refute has_element?(lv, "#profile_form")
      assert has_element?(lv, "#email_form")
      assert Emisar.Repo.reload!(user).full_name == user.full_name

      lv |> element("#change-name") |> render_click()
      assert has_element?(lv, "#profile_full_name[value='#{user.full_name}']")
      assert has_element?(lv, "#profile_form button[disabled]", "Save")
    end

    test "invalid names keep the editor open and report a field error", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      lv |> element("#change-name") |> render_click()
      draft = String.duplicate("x", 256)

      lv |> form("#profile_form", profile: %{full_name: draft}) |> render_submit()

      assert has_element?(lv, "#profile_form", "should be at most 255 character(s)")
      assert has_element?(lv, "#profile_full_name[value='#{draft}']")
      assert Emisar.Repo.reload!(user).full_name == user.full_name
    end

    test "a save after the user is deleted keeps the typed name and reports the failure", %{
      conn: conn
    } do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      lv |> element("#change-name") |> render_click()
      Fixtures.Users.mark_user_as_deleted(user)

      html =
        lv
        |> form("#profile_form", %{"profile" => %{"full_name" => "Unsaved Name"}})
        |> render_submit()

      assert html =~ "Couldn&#39;t update your name. Try again."
      assert html =~ ~s(value="Unsaved Name")
    end
  end

  describe "email form" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "an address rejected after proof keeps the draft and shows its error locally", %{
      conn: conn,
      user: user,
      account: account
    } do
      other = Fixtures.Users.create_user()
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => other.email}})
      |> render_submit()

      assert_received {:email, email}

      render_hook(lv, "confirm_email_change", %{
        "email_step" => %{"code" => Fixtures.Auth.code_from_email(email)}
      })

      assert has_element?(lv, "#email_form", "Couldn't change to that email")
      assert has_element?(lv, "#email_form input[value='#{other.email}']")
      refute has_element?(lv, "#email_step_form")
      assert Emisar.Repo.reload!(user).email == user.email

      lv
      |> form("#email_form", %{"email" => %{"email" => "corrected@example.com"}})
      |> render_change()

      refute has_element?(lv, "#email_form", "Couldn't change to that email")
      assert has_element?(lv, "#email_form input[value='corrected@example.com']")
    end

    test "a change needs a confirmation code (no MFA) — not applied until confirmed", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Submitting only STARTS the step-up — the email is not changed yet.
      html =
        lv
        |> edit_email()
        |> form("#email_form", %{"email" => %{"email" => "fresh@example.com"}})
        |> render_submit()

      assert html =~ "emailed a confirmation code"
      assert has_element?(lv, "#email_step_form button", "Change email")
      assert html =~ "enter the 6-digit code sent to"
      assert html =~ user.email
      assert Emisar.Repo.reload!(user).email == user.email

      # A wrong code is refused and the email stays put. The code boxes are
      # client-owned (CodeInput hook fills the hidden aggregate), so drive the
      # submit event directly rather than through the un-settable hidden field.
      render_hook(lv, "confirm_email_change", %{"email_step" => %{"code" => "000000"}})

      # The rejection renders inline at the code input, not in a transient flash.
      assert lv |> element("#email_step_form") |> render() =~ "incorrect or expired"
      assert_push_event(lv, "code:reset", %{id: "email-step-code"})
      assert Emisar.Repo.reload!(user).email == user.email
    end

    test "a confirm_email_change with no step-up in progress fails closed (no LiveView crash)", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # email_step is :idle (no save started) and the confirm form isn't even
      # rendered. A crafted confirm event over the socket must NOT crash the
      # LiveView (IL-15: never trust the rendered UI) — it fails closed.
      html = render_hook(lv, "confirm_email_change", %{"email_step" => %{"code" => "123456"}})

      assert html =~ "Start an email change first."
      assert Emisar.Repo.reload!(user).email == user.email
    end

    test "a resend_email_code with no step-up in progress fails closed (no LiveView crash)", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # email_step is :idle, so pending_new_email is nil — a crafted resend over
      # the socket must neither crash on the nil email nor claim a code was sent.
      html = render_hook(lv, "resend_email_code", %{})

      assert html =~ "Start an email change first."
      refute html =~ "We sent a new code"
      refute_received {:email, _}
    end

    test "a resend during the TOTP step is refused — the domain chose the authenticator factor",
         %{
           conn: conn,
           user: user,
           account: account
         } do
      secret = Auth.generate_mfa_secret()
      {:ok, _user, _codes} = Fixtures.Users.enroll_mfa(secret, owner_subject(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "mfa-fresh@example.com"}})
      |> render_submit()

      # The step-up is :totp (no resend button rendered) — a forged resend must
      # not mint an emailed code beside the authenticator challenge.
      html = render_hook(lv, "resend_email_code", %{})

      assert html =~ "Start an email change first."
      refute_received {:email, _}
    end

    test "a resend during the pending step sends a fresh working code and clears a stale error",
         %{
           conn: conn,
           user: user,
           account: account
         } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "fresh@example.com"}})
      |> render_submit()

      assert_received {:email, _first_code_email}

      render_hook(lv, "confirm_email_change", %{"email_step" => %{"code" => "000000"}})
      assert lv |> element("#email_step_form") |> render() =~ "incorrect or expired"

      html = lv |> element("#email_step_form button", "Resend code") |> render_click()

      # Success is claimed only after the issue call actually ran — a fresh code
      # was emailed — and the stale rejection no longer sits under the input.
      assert html =~ "We sent a new code to"
      refute html =~ "incorrect or expired"
      assert_received {:email, resent_email}
      code = Fixtures.Auth.code_from_email(resent_email)

      render_hook(lv, "confirm_email_change", %{"email_step" => %{"code" => code}})
      assert Emisar.Repo.reload!(user).email == "fresh@example.com"
    end

    test "resends share the issuance budget and keep the latest code usable", %{
      conn: conn,
      user: user,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "fresh@example.com"}})
      |> render_submit()

      assert_received {:email, _initial_email}

      latest_email =
        Enum.reduce(1..4, nil, fn _, _previous ->
          lv |> element("#email_step_form button", "Resend code") |> render_click()
          assert_received {:email, email}
          email
        end)

      latest_code = Fixtures.Auth.code_from_email(latest_email)

      html = lv |> element("#email_step_form button", "Resend code") |> render_click()

      assert html =~ "Too many code requests. Wait up to 15 minutes, then try again."
      refute_received {:email, _}

      # The refused sixth issuance did not replace the fifth token, and the
      # pending step remains open instead of stranding the operator.
      render_hook(lv, "confirm_email_change", %{"email_step" => %{"code" => latest_code}})
      assert Emisar.Repo.reload!(user).email == "fresh@example.com"
    end

    test "an exhausted issuance budget refuses a fresh step without sending mail", %{
      conn: conn,
      user: user,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      subject = owner_subject(user, account)

      for index <- 1..5 do
        assert Auth.issue_email_change_code("spent-#{index}@example.com", subject) == {:ok, :sent}
        assert_received {:email, _}
      end

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        lv
        |> edit_email()
        |> form("#email_form", %{"email" => %{"email" => "fresh@example.com"}})
        |> render_submit()

      assert html =~ "Too many code requests. Wait up to 15 minutes, then try again."
      assert has_element?(lv, "#email_form")
      refute has_element?(lv, "#email_step_form")
      refute_received {:email, _}
      assert Emisar.Repo.reload!(user).email == user.email
    end

    test "starting after the user is deleted reports failure instead of crashing", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      Fixtures.Users.mark_user_as_deleted(user)

      html =
        lv
        |> edit_email()
        |> form("#email_form", %{"email" => %{"email" => "fresh@example.com"}})
        |> render_submit()

      assert html =~ "Couldn&#39;t start the email change. Try again."
      assert has_element?(lv, "#email_form")
      refute_received {:email, _}
    end

    test "starting a fresh step-up clears a stale inline rejection", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "first@example.com"}})
      |> render_submit()

      render_hook(lv, "confirm_email_change", %{"email_step" => %{"code" => "000000"}})
      assert lv |> element("#email_step_form") |> render() =~ "incorrect or expired"

      # The email form isn't rendered mid-step, but the event stays reachable
      # over the socket — a restarted challenge must not open already accusing
      # the operator of the prior challenge's wrong code.
      render_hook(lv, "save_email", %{"email" => %{"email" => "second@example.com"}})

      refute lv |> element("#email_step_form") |> render() =~ "incorrect or expired"
    end

    test "a resend after the user is deleted reports failure instead of claiming success", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "fresh@example.com"}})
      |> render_submit()

      Fixtures.Users.mark_user_as_deleted(user)

      html = lv |> element("#email_step_form button", "Resend code") |> render_click()

      assert html =~ "Couldn&#39;t send a new code. Try again."
      refute html =~ "We sent a new code"
    end

    test "an MFA-on user confirms with a TOTP code, then the email changes", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()
      {:ok, _user, _codes} = Fixtures.Users.enroll_mfa(secret, owner_subject(user, account))

      # Clear the consumed-bucket marker so a fresh code this same 30s window
      # isn't read as a replay of the enrollment code.
      {:ok, _} = user |> Ecto.Changeset.change(mfa_last_used_at: nil) |> Emisar.Repo.update()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # MFA-on → an authenticator prompt, no emailed code.
      html =
        lv
        |> edit_email()
        |> form("#email_form", %{"email" => %{"email" => "mfa-fresh@example.com"}})
        |> render_submit()

      assert html =~ "authenticator"
      assert Emisar.Repo.reload!(user).email == user.email

      html =
        render_hook(lv, "confirm_email_change", %{
          "email_step" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert html =~ "Email changed. Check mfa-fresh@example.com for a confirmation link."
      assert has_element?(lv, "#email", "Awaiting confirmation")
      refute has_element?(lv, "#email_form")
      updated = Emisar.Repo.reload!(user)
      assert updated.email == "mfa-fresh@example.com"
      assert is_nil(updated.confirmed_at)
    end

    test "an exhausted MFA window refuses the confirmation inline, email unchanged", %{
      conn: conn,
      user: user,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "mfa-fresh@example.com"}})
      |> render_submit()

      # Spend the shared per-user window elsewhere; the step-up here inherits it.
      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(enrolled, {:totp, "000000"}) == {:error, :invalid}
      end

      render_hook(lv, "confirm_email_change", %{
        "email_step" => %{"code" => NimbleTOTP.verification_code(secret)}
      })

      # The refusal renders at the code input and the step stays open to retry.
      assert lv |> element("#email_step_form") |> render() =~
               "Too many attempts. Wait a few minutes, then try again."

      assert Emisar.Repo.reload!(user).email == user.email
    end

    test "a malformed email is refused with an inline changeset error", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      original_email = user.email

      html =
        lv
        |> edit_email()
        |> form("#email_form", %{"email" => %{"email" => "not-an-email"}})
        |> render_submit()

      assert html =~ "must have the @ sign and no spaces"
      assert Emisar.Repo.reload!(user).email == original_email
    end

    test "cancelling the step-up returns to the current address, email unchanged", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv
      |> edit_email()
      |> form("#email_form", %{"email" => %{"email" => "fresh@example.com"}})
      |> render_submit()

      html = lv |> element("#email_step_form button", "Cancel") |> render_click()

      assert html =~ user.email
      assert has_element?(lv, "#change-email")
      refute has_element?(lv, "#email_form")
      refute has_element?(lv, "#email_step_form")
      assert Emisar.Repo.reload!(user).email == user.email
    end
  end

  describe "OIDC sign-in methods" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})

      provider =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          name: "Workforce Okta"
        )

      %{account: account, conn: conn, provider: provider, user: user}
    end

    test "lists an enabled workspace provider with linking guidance", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert html =~ "Sign-in methods"

      assert has_element?(
               lv,
               "#single-sign-on-help",
               "Each workspace sets its own sign-in rules."
             )

      assert has_element?(lv, "#oidc-identity-#{provider.id}", "Workforce Okta")
      assert has_element?(lv, "#link-oidc-#{provider.id}", "Link")

      assert has_element?(
               lv,
               "#link-oidc-#{provider.id}[phx-hook='PendingButton'][phx-disable-with='Linking…']"
             )
    end

    test "a crafted start_oidc_unlink does not crash the socket", %{conn: conn, account: account} do
      # An enabled-but-unlinked provider entry carries identity_id: nil, so a crafted
      # null (or non-binary) identity_id matched a non-removable, non-linked entry and
      # CaseClauseError'd the socket; the guard + total case make it a no-op.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_hook(lv, "start_oidc_unlink", %{"identity_id" => nil})
      assert render_hook(lv, "start_oidc_unlink", %{"identity_id" => ["x"]})
    end

    test "keeps a wrong local proof inline and arms only a valid handoff", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv |> element("#link-oidc-#{provider.id}") |> render_click()
      assert_received {:email, email}
      assert has_element?(lv, "#profile-oidc-step-form")

      wrong =
        render_hook(lv, "confirm_oidc_step_up", %{
          "oidc_step" => %{"code" => "000000"}
        })

      assert wrong =~ "incorrect or expired"
      refute wrong =~ ~s(name="handoff")
      assert_push_event(lv, "code:reset", %{id: "profile-oidc-step-code"})

      confirmed =
        render_hook(lv, "confirm_oidc_step_up", %{
          "oidc_step" => %{"code" => Fixtures.Auth.code_from_email(email)}
        })

      assert confirmed =~ "phx-trigger-action"
      assert confirmed =~ ~s(action="/app/#{account.slug}/settings/sso/identity/link")
      assert confirmed =~ ~s(name="handoff")
    end

    test "a provider-linked identity labels its verification pending state", %{
      conn: conn,
      account: account,
      provider: provider,
      user: user
    } do
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id
      })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#link-oidc-#{provider.id}", "Verify")

      assert has_element?(
               lv,
               "#link-oidc-#{provider.id}[phx-hook='PendingButton'][phx-disable-with='Verifying…']"
             )
    end

    test "resends visibly and closes the link dialog through server state", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      lv |> element("#link-oidc-#{provider.id}") |> render_click()
      assert_received {:email, _email}

      html = render(lv)
      assert html =~ ~s(id="profile-oidc-step-close")
      assert html =~ ~s(id="profile-oidc-step-resend")
      assert html =~ "hover:bg-zinc-800"
      assert has_element?(lv, "#profile-oidc-step-form button", "Cancel")
      assert has_element?(lv, "#profile-oidc-step-continue", "Continue to Workforce Okta")

      assert has_element?(
               lv,
               "#profile-oidc-step-continue[class~='min-w-28'][phx-hook='PendingButton'][phx-disable-with='Confirming...']"
             )

      assert has_element?(
               lv,
               "#profile-oidc-step-resend[phx-hook='PendingButton'][phx-disable-with='Sending…']"
             )

      lv |> element("#profile-oidc-step-resend") |> render_click()
      assert_received {:email, _replacement_email}
      assert_push_event(lv, "code:reset", %{id: "profile-oidc-step-code"})
      assert render(lv) =~ "We sent a new code"

      lv |> element("#profile-oidc-step-close") |> render_click()
      refute has_element?(lv, "#profile-oidc-step-form")
    end

    test "a user-verified identity has explicit removal friction and unlinks inline", %{
      conn: conn,
      account: account,
      provider: provider,
      user: user
    } do
      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id,
          created_by: :user,
          provisioned_via: :oidc_link
        })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert html =~ "Linked by you"
      assert has_element?(lv, "#remove-oidc-#{provider.id}", "Remove")
      refute has_element?(lv, "#remove-oidc-dialog-#{provider.id}")
      lv |> element("#remove-oidc-#{provider.id}") |> render_click()
      assert_received {:email, email}
      assert has_element?(lv, "#profile-oidc-step", "Type Workforce Okta to confirm")
      assert has_element?(lv, "#profile-oidc-step-continue[disabled]", "Remove sign-in method")

      for token <- [nil, "Wrong provider"] do
        render_hook(lv, "confirm_oidc_step_up", %{
          "confirm_token" => token,
          "oidc_step" => %{"code" => Fixtures.Auth.code_from_email(email)}
        })

        assert has_element?(
                 lv,
                 "#profile-oidc-step",
                 "Enter the provider name to confirm removal."
               )

        refute Emisar.Repo.reload!(identity).deleted_at
        refute_push_event(lv, "code:reset", %{id: "profile-oidc-step-code"})
      end

      lv
      |> form("#profile-oidc-step-form", %{"confirm_token" => provider.name})
      |> render_change()

      refute has_element?(lv, "#profile-oidc-step-continue[disabled]")

      html =
        render_hook(lv, "confirm_oidc_step_up", %{
          "confirm_token" => provider.name,
          "oidc_step" => %{"code" => Fixtures.Auth.code_from_email(email)}
        })

      assert html =~ "Workforce Okta was removed from your profile."
      refute has_element?(lv, "#remove-oidc-#{provider.id}")
      assert has_element?(lv, "#link-oidc-#{provider.id}", "Link")
      assert Emisar.Repo.reload!(identity).deleted_at
    end

    test "a forged provider id outside the current workspace fails closed", %{
      conn: conn,
      account: account
    } do
      foreign = Fixtures.SSO.create_identity_provider(name: "Foreign Provider")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "start_oidc_link", %{"provider_id" => foreign.id})

      assert html =~ "That sign-in method is no longer available."
      refute_received {:email, _email}
    end

    test "a required method remains user-linked and explains blocked removal before proof", %{
      conn: conn,
      account: account,
      provider: provider,
      user: user
    } do
      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id,
          created_by: :user,
          provisioned_via: :oidc_link
        })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      render_click(lv, "retry_oidc_identities", %{})

      assert has_element?(lv, "#oidc-identity-#{provider.id}", "Linked by you")
      assert has_element?(lv, "#remove-oidc-#{provider.id}[disabled]")
      refute has_element?(lv, "#link-oidc-#{provider.id}")

      assert has_element?(
               lv,
               "#remove-oidc-reason-#{provider.id}",
               "Link another enabled sign-in method before removing this one."
             )

      render_click(lv, "start_oidc_unlink", %{"identity_id" => identity.id})
      refute has_element?(lv, "#profile-oidc-step")
      refute_received {:email, _}
    end

    test "a crafted step-up event with nothing in progress spends no attempt", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      confirmed = render_hook(lv, "confirm_oidc_step_up", %{"oidc_step" => %{"code" => "000000"}})

      assert confirmed =~ "Choose a sign-in method first."
      assert render_hook(lv, "resend_oidc_step_up", %{}) =~ "Start the confirmation again."
      refute_received {:email, _email}
    end
  end

  describe "sessions" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "lists sessions and revokes the selected one", %{
      conn: conn,
      user: user,
      account: account
    } do
      # A second session for the same user (another device).
      other_conn = build_conn() |> log_in_user(user)
      _ = other_conn

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      html = render(lv)
      assert html =~ "This session"

      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject, page: [limit: 100])
      assert length(sessions) == 2

      html = render_click(lv, "revoke_other_sessions", %{})
      assert html =~ "Other sessions signed out."

      {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject, page: [limit: 100])
      assert length(sessions) == 1
    end

    test "lists each session and marks the current device", %{
      conn: conn,
      user: user,
      account: account
    } do
      # A second device with recognizable metadata so its row renders distinctly
      # from the current session.
      _other =
        Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
          ip_address: "198.51.100.4",
          user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
        })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      # The current session carries the "This session" marker; the second device
      # renders its IP + parsed label in its own row. Rows order by recency, so
      # position isn't asserted — the marker, not the slot, orients the operator.
      assert html =~ "This session"
      assert html =~ "198.51.100.4"
      assert html =~ "Chrome 124.0 on Linux"
      assert has_element?(lv, "#active-sessions li", "Email link")
      assert has_element?(lv, "#active-sessions li", "Sign-in IP:")
      assert has_element?(lv, "#active-sessions time[data-format=absolute][data-tooltip-id]")
      refute has_element?(lv, "#active-sessions", "Last active")
      assert has_element?(lv, "#active-sessions li", "This session")

      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject, page: [limit: 100])
      assert length(sessions) == 2
    end

    test "shows the recorded sign-in method and honest missing metadata", %{
      conn: conn,
      user: user,
      account: account
    } do
      Fixtures.Auth.create_session_token!(user, :sso, nil)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert has_element?(lv, "#active-sessions li", "Single sign-on")
      assert has_element?(lv, "#active-sessions li", "Sign-in IP: Not recorded")
      assert has_element?(lv, "#active-sessions li", "Unknown device")
    end

    test "links separately to this user's agents in the current workspace", %{
      conn: conn,
      user: user,
      account: account
    } do
      other = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: other.id,
          role: "operator"
        )

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(
          %{name: "Someone else's agent"},
          Fixtures.Subjects.membership_subject(membership)
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      href = ~p"/app/#{account}/agents?#{[owner: user.id]}"
      assert has_element?(lv, ~s(#sessions-help p + p a[href="#{href}"]), "Review your agents")

      {:ok, agents, _html} =
        lv |> element("#review-your-agents") |> render_click() |> follow_redirect(conn, href)

      assert has_element?(agents, "select[name=owner] option[selected]", user.email)
      assert has_element?(agents, "a", "Clear filters")
      assert render(agents) =~ "No agents match these filters."
      refute render(agents) =~ "Someone else&#39;s agent"
    end

    test "does not offer Agents to a billing manager", %{account: account} do
      user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "billing_manager"
      )

      {:ok, lv, _html} =
        live(log_in_user(build_conn(), user), ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#sessions-help", "Don't recognize a session?")
      refute has_element?(lv, "#review-your-agents")
    end

    test "the own-agents filter stays readable for a profile without email", %{account: account} do
      user = Fixtures.Users.create_sso_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "viewer"
      )

      conn = log_in_user(build_conn(), user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      href = ~p"/app/#{account}/agents?#{[owner: user.id]}"

      {:ok, agents, _html} =
        lv |> element("#review-your-agents") |> render_click() |> follow_redirect(conn, href)

      assert has_element?(agents, "select[name=owner] option[selected]", "You")
      assert render(agents) =~ "No agents match these filters."
    end

    test "caps the page at 10 sessions and pages the rest", %{
      conn: conn,
      user: user,
      account: account
    } do
      # 10 more devices on top of the current session — 11 total, one past a page.
      for n <- 1..10 do
        Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
          ip_address: "203.0.113.#{n}",
          user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
        })
      end

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Page one holds exactly 10 rows and a pager that names the 11 total.
      assert rendered_session_rows(lv) == 10
      assert has_element?(lv, "#active-sessions-pager", "11")
      assert has_element?(lv, "#active-sessions-pager a", "Next")

      # Following Next patches to page two — the 11th session, and the way back.
      html = lv |> element("#active-sessions-pager a", "Next") |> render_click()
      assert rendered_session_rows(lv) == 1
      assert html =~ "Prev"

      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject, page: [limit: 100])
      oldest_session = List.last(sessions)

      html = render_hook(lv, "revoke_session", %{"id" => oldest_session.id})

      assert rendered_session_rows(lv) == 0
      assert html =~ "This page no longer has results."
      assert has_element?(lv, "#active-sessions-pager a", "Back to first page")

      lv |> element("#active-sessions-pager a", "Back to first page") |> render_click()
      assert rendered_session_rows(lv) == 10
    end

    test "a session with no user agent shows the unknown-device mark", %{
      conn: conn,
      user: user,
      account: account
    } do
      # A session recorded without a User-Agent header — the row still has to
      # name a device class, and UserAgent owns what that is. A local fallback
      # here once answered `infrastructure.network`, putting a globe in a column
      # of device silhouettes while the drawing made for this case went unused.
      Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
        ip_address: "198.51.100.7"
      })

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert html =~ "Unknown device"
      assert html =~ "device.unknown"
      refute html =~ "infrastructure.network"
    end

    test "renders and revokes same-device sessions independently", %{
      conn: conn,
      user: user,
      account: account
    } do
      user_agent = "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"

      Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
        ip_address: "203.0.113.10",
        user_agent: user_agent
      })

      Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
        ip_address: "203.0.113.11",
        user_agent: user_agent
      })

      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject, page: [limit: 100])
      first_session = Enum.find(sessions, &(&1.ip_address == "203.0.113.10"))
      second_session = Enum.find(sessions, &(&1.ip_address == "203.0.113.11"))

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      refute html =~ "2 sessions"
      assert has_element?(lv, "#active-sessions > li", "203.0.113.10")
      assert has_element?(lv, "#active-sessions > li", "203.0.113.11")

      html = render_click(lv, "revoke_session", %{"id" => first_session.id})

      assert html =~ "Session signed out."
      refute html =~ "203.0.113.10"
      assert html =~ "203.0.113.11"

      assert {:ok, remaining, _meta} =
               Auth.list_sessions_for_user(nil, subject, page: [limit: 100])

      refute Enum.any?(remaining, &(&1.id == first_session.id))
      assert Enum.any?(remaining, &(&1.id == second_session.id))
    end

    test "revoking one non-current session removes exactly that row", %{
      conn: conn,
      user: user,
      account: account
    } do
      # A second device — the row we'll revoke. It's the one the caller's own
      # session token does NOT mark as current.
      Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
        user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
      })

      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, sessions, _meta} =
        Auth.list_sessions_for_user(Emisar.Crypto.hash(session_token(conn)), subject,
          page: [limit: 100]
        )

      other = Enum.find(sessions, &(not &1.current?))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_session", %{"id" => other.id}) =~ "Session signed out."

      # Down to one — only the current device remains.
      {:ok, remaining, _meta} = Auth.list_sessions_for_user(nil, subject, page: [limit: 100])
      assert length(remaining) == 1
      refute Enum.any?(remaining, &(&1.id == other.id))
    end

    test "the current device row offers no Revoke control", %{
      conn: conn,
      user: user,
      account: account
    } do
      # Two devices: one current, one other. The other carries a sign-out control;
      # the current device must not (you can't sign yourself out from here —
      # that's "sign out everywhere else").
      Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
        user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
      })

      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, sessions, _meta} =
        Auth.list_sessions_for_user(Emisar.Crypto.hash(session_token(conn)), subject,
          page: [limit: 100]
        )

      other = Enum.find(sessions, &(not &1.current?))
      current = Enum.find(sessions, & &1.current?)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert has_element?(lv, "#signout-session-#{other.id}")

      refute has_element?(lv, "#signout-session-#{current.id}")
    end

    test "revoke_other_sessions with nothing to revoke says so", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_other_sessions", %{}) =~ "No other sessions to sign out."
    end

    test "large session lists stay bounded in the context and on the page", %{
      conn: conn,
      user: user,
      account: account
    } do
      # 100 more sessions (register_and_log_in already created one) → 101 total.
      for _ <- 1..100, do: Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject, page: [limit: 100])
      assert length(sessions) == 100

      # The page renders only ten while exposing the total and bulk action.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert rendered_session_rows(lv) == 10
      assert has_element?(lv, "#active-sessions-pager", "101")
      assert html =~ "Sign out everywhere else"
    end

    test "the disconnected (dead) render reads no session metadata", %{
      conn: conn,
      user: user,
      account: account
    } do
      # IL-18: the session list is the only DB read on this page, gated behind
      # connected?/1 — so the dead render a plain GET produces must not include
      # session rows, even though a real session exists. A second device is seeded
      # so "no rows on the dead render" is meaningful.
      _other =
        Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
          ip_address: "203.0.113.9",
          user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) Safari/17.0"
        })

      dead = conn |> get(~p"/app/#{account}/settings/profile") |> html_response(200)

      # The seeded device's metadata is NOT read on the dead pass.
      assert dead =~ "Loading sessions"
      assert dead =~ "Loading sign-in methods"
      refute dead =~ "No single sign-on providers are enabled"
      refute dead =~ "203.0.113.9"
      refute dead =~ "This session"
    end

    test "failed reads stay distinct from empty lists and offer local retry", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      original_subject = :sys.get_state(lv.pid).socket.assigns.current_subject

      :sys.replace_state(lv.pid, fn state ->
        socket =
          Phoenix.Component.assign(state.socket, :current_subject, %{
            original_subject
            | actor: nil,
              permissions: MapSet.new()
          })

        %{state | socket: socket}
      end)

      render_click(lv, "retry_oidc_identities", %{})
      render_click(lv, "retry_sessions", %{})
      assert has_element?(lv, "#sessions", "Couldn't load your sessions")
      assert has_element?(lv, "button[phx-click=retry_sessions]", "Retry")
      refute has_element?(lv, "#active-sessions")
      assert has_element?(lv, "#single-sign-on", "Couldn't load sign-in methods")
      assert has_element?(lv, "button[phx-click=retry_oidc_identities]", "Retry")
      refute has_element?(lv, "#single-sign-on", "No single sign-on providers are enabled")

      :sys.replace_state(lv.pid, fn state ->
        %{
          state
          | socket: Phoenix.Component.assign(state.socket, :current_subject, original_subject)
        }
      end)

      render_click(lv, "retry_oidc_identities", %{})
      render_click(lv, "retry_sessions", %{})
      refute has_element?(lv, "button[phx-click=retry_sessions]")
      assert has_element?(lv, "#active-sessions", "This session")
      refute has_element?(lv, "button[phx-click=retry_oidc_identities]")
      assert has_element?(lv, "#single-sign-on", "No single sign-on providers are enabled")
    end

    test "revoking a session removed after mount refreshes the displayed list", %{
      conn: conn,
      user: user,
      account: account
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(user, account)
      current_digest = Emisar.Crypto.hash(session_token(conn))
      {:ok, sessions, _meta} = Auth.list_sessions_for_user(current_digest, subject)
      other = Enum.find(sessions, &(not &1.current?))
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert has_element?(lv, "#sessions-#{other.id}")

      Fixtures.Auth.delete_session_token!(token)

      assert render_click(lv, "revoke_session", %{"id" => other.id}) =~
               "This session has already ended."

      refute has_element?(lv, "#sessions-#{other.id}")
      assert has_element?(lv, "#active-sessions", "This session")
    end

    test "the rendered session rows never surface the raw token (only id + metadata)", %{
      conn: conn,
      user: user,
      account: account
    } do
      # A second session minted with a recognizable device (the metadata DOES
      # render) — and we keep the raw token it returns. The token is stored
      # hashed (UserToken.token holds the digest); neither the raw token nor its
      # digest may ever reach the rendered rows — only id + inserted_at + the
      # ip/user-agent metadata.
      raw_token =
        Fixtures.Auth.create_session_token!(user, :magic_link, nil, %{
          ip_address: "203.0.113.7",
          user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) Firefox/126.0"
        })

      digest = Emisar.Crypto.hash(raw_token)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      # The row renders from metadata, so the device + IP are visible…
      assert html =~ "Firefox 126.0 on Mac"
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
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "email proof → authenticator confirm enables MFA and shows recovery codes once", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = begin_mfa_enrollment(lv)
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
      assert has_element?(lv, "#mfa-recovery-codes")
      refute has_element?(lv, "#multi-factor-authentication-help")

      # The voluntary reveal offers a file download too (matching the enforced
      # setup path) — a clipboard is too volatile for a lockout credential.
      assert html =~ ~s(download="emisar-recovery-codes.txt")

      # Once saved, the MFA-on view surfaces how many codes remain (a fresh 10,
      # so no low-count nudge).
      assert has_element?(lv, "#mfa-recovery-codes button[disabled]", "Done")
      render_click(lv, "dismiss_recovery_codes", %{})
      assert has_element?(lv, "#mfa-recovery-codes")
      render_click(lv, "toggle_codes_saved", %{})
      html = render_click(lv, "dismiss_recovery_codes", %{})
      refute has_element?(lv, "#mfa-recovery-codes")
      assert has_element?(lv, "#multi-factor-authentication", "10 recovery codes remaining")
      refute has_element?(lv, "#multi-factor-authentication-help")
      refute html =~ "Generate new codes before these run out."
    end

    test "mount and refresh send no enrollment mail; the explicit start reveals no secret", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      refute html =~ "mfa-setup-key"
      assert has_element?(lv, "#multi-factor-authentication", "Not enabled")
      assert has_element?(lv, "#mfa-status > button[phx-click=start_mfa]", "Set up MFA")

      assert has_element?(
               lv,
               "aside#multi-factor-authentication-help",
               "We recommend enabling MFA to help protect your profile."
             )

      refute has_element?(lv, "#multi-factor-authentication > div", "recommend")
      refute html =~ "First verify your email"
      refute html =~ "Keep your recovery codes somewhere"
      refute html =~ "Email verification code"
      refute_received {:email, _}

      html = render_click(lv, "start_mfa", %{})

      assert html =~ "Email verification code"
      refute has_element?(lv, "#multi-factor-authentication-help")
      refute has_element?(lv, "#multi-factor-authentication", "Not enabled")
      refute has_element?(lv, "#mfa-status")
      refute html =~ "mfa-setup-key"
      assert_received {:email, _}

      render_click(lv, "cancel_mfa", %{})
      assert has_element?(lv, "#multi-factor-authentication-help", "We recommend enabling MFA")
    end

    test "a suppressed current address does not claim or advance delivery", %{
      conn: conn,
      account: account,
      user: user
    } do
      assert {:ok, _suppression} =
               Emisar.Mail.suppress(user.email, :hard_bounce, "bounce")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "start_mfa", %{})

      assert html =~ "cannot deliver mail to your current address"
      assert html =~ "Contact support"
      refute html =~ "Email verification code"
      refute html =~ "mfa-setup-key"
      refute_received {:email, _}
    end

    test "a wrong or out-of-sequence inbox code never reveals the authenticator secret", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        render_hook(lv, "verify_mfa_enrollment_email", %{
          "mfa_enrollment" => %{"code" => "000000"}
        })

      assert html =~ "Start MFA setup again."
      refute html =~ "mfa-setup-key"

      render_click(lv, "start_mfa", %{})
      assert_received {:email, _}

      html =
        render_hook(lv, "verify_mfa_enrollment_email", %{
          "mfa_enrollment" => %{"code" => "000000"}
        })

      assert html =~ "incorrect or expired"
      refute html =~ "mfa-setup-key"
      assert_push_event(lv, "code:reset", %{id: "mfa-enrollment-email-code"})
    end

    test "the enrollment QR is a server-rendered inline SVG, not a third-party image", %{
      conn: conn,
      account: account
    } do
      # The otpauth URI carries the TOTP secret, so it must never be handed to an
      # external QR-image service. EmisarWeb.MfaQr renders the code as an inline
      # SVG server-side; `raw/1` on that markup is the documented IL-16 exception
      # (server-generated, not untrusted input). Assert the SVG is inlined and no
      # external image/script is the QR source.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = begin_mfa_enrollment(lv)

      # The QR is an inlined <svg> (EQRCode), with the manual-entry fallback key
      # present in the page…
      assert html =~ "<svg"
      assert html =~ "mfa-setup-key"
      refute html =~ "otpauth://totp/"
      # …and the secret-bearing URI is NEVER handed to a remote image: it isn't an
      # <img src=> at all, and no known QR-image service host appears.
      refute html =~ ~r/<img[^>]+otpauth/
      refute html =~ "chart.googleapis.com"
      refute html =~ "api.qrserver.com"
    end

    test "a low recovery-code count nudges to regenerate (amber)", %{
      conn: conn,
      user: user,
      account: account
    } do
      # MFA on with only 2 codes left (8 burned down on lost-device sign-ins) —
      # tracked all along but never shown until now.
      user
      |> Ecto.Changeset.change(
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: ["digest-1", "digest-2"]
      )
      |> Emisar.Repo.update!()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#multi-factor-authentication", "2 recovery codes remaining")
      assert html =~ "Generate new codes before these run out."
    end

    test "a wrong OTP leaves MFA off with the error inline at the code input", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      begin_mfa_enrollment(lv)

      render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => "000000"}})

      # The rejection renders inside the enrollment form (not a transient flash),
      # and the QR stays up so the operator can retry with the next code.
      assert lv |> element("#mfa_form") |> render() =~ "That code didn&#39;t match"
      assert has_element?(lv, "#mfa-otp")
      assert_push_event(lv, "code:reset", %{id: "mfa-otp"})
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "a stale profile view refreshes when another session enables MFA", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      {_user, _codes} =
        Fixtures.Users.enable_mfa!(
          Auth.generate_mfa_secret(),
          Fixtures.Subjects.subject_for(user, account)
        )

      render_click(lv, "start_mfa", %{})

      assert_redirect(lv, ~p"/app/#{account}/settings/profile")
    end

    test "a concurrent enrollment completion refreshes the profile MFA state", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      pending_secret = lv |> begin_mfa_enrollment() |> mfa_secret_from()

      {_user, _codes} =
        Fixtures.Users.enable_mfa!(
          Auth.generate_mfa_secret(),
          Fixtures.Subjects.subject_for(user, account)
        )

      submit_concurrent_mfa_enrollment(lv, pending_secret)

      assert_redirect(lv, ~p"/app/#{account}/settings/profile")
    end

    test "a non-numeric OTP is rejected and MFA stays off", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Start the enable flow so a pending secret is stashed, then submit a
      # six-char *non-numeric* code. NimbleTOTP compares it against the
      # secret-derived digits and it can't match, so enrollment is refused.
      begin_mfa_enrollment(lv)

      html = render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => "abc123"}})

      assert html =~ "That code didn&#39;t match"
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "a code from a prior 30s bucket is rejected (no leeway)", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = begin_mfa_enrollment(lv)
      secret = mfa_secret_from(html)

      # Crypto.valid_totp? validates only against the CURRENT window with no
      # leeway, so a code minted two buckets back can never match the live one —
      # the offset is large enough that a window straddle can't make it collide.
      stale_otp =
        NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 90)

      html = render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => stale_otp}})

      assert html =~ "That code didn&#39;t match"
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "dismissing the recovery-codes reveal hides them and they're not re-shown", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, [proof_code | _]} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Regenerate to reveal a fresh one-shot set, then dismiss it — the reveal
      # is gone and a fresh mount never re-renders the plaintext codes.
      render_click(lv, "start_regenerate_recovery_codes", %{})

      render_submit(lv, "regenerate_recovery_codes", %{
        "mfa_recovery_regeneration" => %{
          "code" => proof_code
        }
      })

      assert has_element?(lv, "#mfa-recovery-codes")

      # Codes are lowercase base32 (Crypto.mfa_recovery_code/0) — pull one out of
      # the reveal to prove it's gone after dismissal.
      shown = lv |> element("#mfa-recovery-codes") |> render()
      [_, a_code | _] = Regex.run(~r/([a-z2-7]{16})/, shown)
      assert is_binary(a_code)

      render_click(lv, "toggle_codes_saved", %{})
      dismissed = render_click(lv, "dismiss_recovery_codes", %{})
      refute has_element?(lv, "#mfa-recovery-codes")
      refute dismissed =~ a_code

      {:ok, _lv2, remounted} = live(conn, ~p"/app/#{account}/settings/profile")
      refute remounted =~ "mfa-recovery-codes"
      refute remounted =~ a_code
    end

    test "cancel_mfa drops the pending secret so confirm refuses", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      begin_mfa_enrollment(lv)
      render_click(lv, "cancel_mfa", %{})

      # Cancel removes the form from the DOM; a stale client could still
      # push the event, so fire it directly.
      html = render_submit(lv, "confirm_mfa", %{"mfa" => %{"otp" => "123456"}})

      assert html =~ "Start MFA setup again."
    end

    test "disabling MFA without a code is rejected and MFA stays enabled", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "disable_mfa", %{})

      assert html =~ "Authenticator or recovery code"
      assert html =~ "That code did not match. Try again."
      reloaded = Emisar.Repo.reload!(user)
      assert %DateTime{} = reloaded.mfa_enabled_at
    end

    test "regenerate + disable for an MFA-enabled user", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_regenerate_recovery_codes", %{})

      assert render_submit(lv, "regenerate_recovery_codes", %{
               "mfa_recovery_regeneration" => %{
                 "code" => NimbleTOTP.verification_code(secret)
               }
             }) =~ "New recovery codes generated."

      shown = lv |> element("#mfa-recovery-codes") |> render()
      [_, recovery_code | _] = Regex.run(~r/([a-z2-7]{16})/, shown)

      render_click(lv, "start_disable_mfa", %{})

      html =
        render_submit(lv, "disable_mfa", %{"mfa_disable" => %{"code" => recovery_code}})

      # The disable drops this socket too, so it reconnects and the "MFA
      # disabled." flash may not survive the remount. What the operator is
      # actually owed is the durable outcome: the factor is gone and the card
      # offers setup again.
      assert html =~ "Set up MFA"
      refute html =~ "Disable MFA"
      refute Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "recovery-code regeneration refuses missing or wrong proof without replacement", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      old_digests = enrolled.mfa_recovery_codes
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "regenerate_recovery_codes", %{})
      assert html =~ "That code did not match. Try again."
      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(user).mfa_recovery_codes == old_digests

      render_click(lv, "start_regenerate_recovery_codes", %{})

      html =
        render_submit(lv, "regenerate_recovery_codes", %{
          "mfa_recovery_regeneration" => %{"code" => "not-a-code"}
        })

      assert html =~ "That code did not match. Try again."
      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(user).mfa_recovery_codes == old_digests
    end

    test "recovery regeneration start, cancel, and disable forms stay mutually exclusive", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_regenerate_recovery_codes", %{})
      assert has_element?(lv, "#mfa_recovery_regeneration_form")
      refute has_element?(lv, "#mfa_disable_form")

      render_click(lv, "start_disable_mfa", %{})
      refute has_element?(lv, "#mfa_recovery_regeneration_form")
      assert has_element?(lv, "#mfa_disable_form")

      assert has_element?(lv, "#mfa_disable_form button", "Disable MFA")
      refute has_element?(lv, "#mfa_disable_form button", "Confirm and disable")

      disable_submit =
        lv |> element("#mfa_disable_form button", "Disable MFA") |> render()

      assert disable_submit =~ "border-rose-500/40"
      refute disable_submit =~ "bg-brand-500"

      render_click(lv, "start_regenerate_recovery_codes", %{})
      assert has_element?(lv, "#mfa_recovery_regeneration_form")
      refute has_element?(lv, "#mfa_disable_form")

      render_click(lv, "cancel_regenerate_recovery_codes", %{})
      refute has_element?(lv, "#mfa_recovery_regeneration_form")
    end

    test "a replayed authenticator code stays inline and preserves the old set", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      old_digests = enrolled.mfa_recovery_codes
      otp = NimbleTOTP.verification_code(secret)
      assert {:ok, _proof} = Auth.verify_mfa_challenge(enrolled, {:totp, otp})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      render_click(lv, "start_regenerate_recovery_codes", %{})

      html =
        render_submit(lv, "regenerate_recovery_codes", %{
          "mfa_recovery_regeneration" => %{"code" => otp}
        })

      assert html =~ "already used. Wait for the next authenticator code."
      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(user).mfa_recovery_codes == old_digests
    end

    test "a concurrent MFA disable closes stale regeneration controls", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      render_click(lv, "start_regenerate_recovery_codes", %{})

      assert {:ok, _disabled} =
               Emisar.Users.update_user_mfa(user.id, nil, nil, [],
                 audit: &Emisar.Audit.user_changesets(&1, "user.mfa_disabled")
               )

      render_submit(lv, "regenerate_recovery_codes", %{
        "mfa_recovery_regeneration" => %{
          "code" => NimbleTOTP.verification_code(secret)
        }
      })

      assert_redirect(lv, ~p"/app/#{account}/settings/profile")
    end

    test "an exhausted shared MFA window leaves regeneration open and codes unchanged", %{
      conn: conn,
      user: user,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      old_digests = enrolled.mfa_recovery_codes
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      render_click(lv, "start_regenerate_recovery_codes", %{})

      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(enrolled, {:totp, "000000"}) == {:error, :invalid}
      end

      html =
        render_submit(lv, "regenerate_recovery_codes", %{
          "mfa_recovery_regeneration" => %{
            "code" => NimbleTOTP.verification_code(secret)
          }
        })

      assert html =~ "Too many attempts. Wait a few minutes, then try again."
      assert has_element?(lv, "#mfa_recovery_regeneration_form")
      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(user).mfa_recovery_codes == old_digests
    end

    test "a wrong code stays inline and leaves MFA enabled", %{
      conn: conn,
      user: user,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_disable_mfa", %{})

      html =
        render_submit(lv, "disable_mfa", %{
          "mfa_disable" => %{"code" => "not-a-real-code"}
        })

      assert html =~ "That code did not match. Try again."
      refute html =~ "Could not disable MFA."
      assert %DateTime{} = Emisar.Repo.reload!(user).mfa_enabled_at
    end

    test "an exhausted MFA window refuses the disable inline and leaves MFA on", %{
      conn: conn,
      user: user,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Users.enable_mfa!(secret, Fixtures.Subjects.subject_for(user, account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_disable_mfa", %{})

      # Spend the shared per-user window elsewhere; this step-up inherits it.
      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(enrolled, {:totp, "000000"}) == {:error, :invalid}
      end

      otp = NimbleTOTP.verification_code(secret)
      html = render_submit(lv, "disable_mfa", %{"mfa_disable" => %{"code" => otp}})

      # The refusal renders at the code input and the step stays open to retry.
      assert html =~ "Too many attempts. Wait a few minutes, then try again."
      assert html =~ "Authenticator or recovery code"
      assert %DateTime{} = Emisar.Repo.reload!(user).mfa_enabled_at
    end
  end

  # The raw session token the logged-in conn presents — what the page hands
  # `Auth.list_sessions_for_user/3` so its own row comes back `current?: true`.
  defp session_token(conn), do: Plug.Conn.get_session(conn, :user_token)

  # Count of session rows rendered on the current page — each stream row is an
  # <li id="sessions-<uuid>">, so the ids that match are exactly this page's rows.
  defp rendered_session_rows(lv) do
    lv
    |> render()
    |> then(&Regex.scan(~r/id="sessions-[0-9a-f-]+"/, &1))
    |> length()
  end

  defp mfa_secret_from(html) do
    # The setup panel renders the Base32 secret for manual entry.
    [_, encoded] = Regex.run(~r/data-copy-text="([A-Z2-7]+)"/, html)
    Base.decode32!(encoded, padding: false)
  end

  defp edit_email(lv) do
    lv |> element("#change-email") |> render_click()
    lv
  end

  defp begin_mfa_enrollment(lv) do
    render_click(lv, "start_mfa", %{})
    assert_received {:email, email}
    code = Fixtures.Auth.code_from_email(email)

    render_hook(lv, "verify_mfa_enrollment_email", %{
      "mfa_enrollment" => %{"code" => code}
    })
  end

  # Submits the enrollment form, retrying once across a 30s-window straddle (the
  # code-gen/validate boundary) — the same flake Fixtures.Users.enroll_mfa guards, but
  # through the LiveView form. A straddle re-renders the form without the success
  # flash, so a second submit with a fresh code lands in a stable window.
  defp submit_mfa_enrollment(lv, secret) do
    html =
      render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => NimbleTOTP.verification_code(secret)}})

    if html =~ "MFA enabled." do
      html
    else
      render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => NimbleTOTP.verification_code(secret)}})
    end
  end

  # Concurrent-completion tests expect a redirect rather than the success
  # flash above, but have the same real-clock TOTP boundary. Retry only the
  # rendered invalid-code branch once with the next current code.
  defp submit_concurrent_mfa_enrollment(lv, secret) do
    html =
      render_hook(lv, "confirm_mfa", %{
        "mfa" => %{"otp" => NimbleTOTP.verification_code(secret)}
      })

    case html do
      html when is_binary(html) ->
        if html =~ "That code didn" do
          render_hook(lv, "confirm_mfa", %{
            "mfa" => %{"otp" => NimbleTOTP.verification_code(secret)}
          })
        else
          html
        end

      navigation ->
        navigation
    end
  end
end
