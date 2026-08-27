defmodule EmisarWeb.UserSignUpLiveTest do
  @moduledoc """
  Self-serve sign-up: one form validates the future workspace and creates the
  resumable user, then arms the hidden POST that mails the one-time sign-in
  link. The proved inbox factor creates the free workspace and session together.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Users
  alias EmisarWeb.{BillingIntent, RegistrationHandoff}

  defp sign_up_params(overrides \\ %{}) do
    Map.merge(
      %{
        "user" => %{
          "full_name" => "Founder Person",
          "email" => "founder-#{System.unique_integer([:positive])}@example.com"
        },
        "account_name" => "Founder Co"
      },
      overrides
    )
  end

  defp neutral_response_shape(html) do
    %{
      posts_to_magic_start?: html =~ ~s|action="/sign_in/magic/start"|,
      triggers_post?: html =~ "phx-trigger-action",
      handoff_fields: length(Regex.scan(~r/name="registration_handoff"/, html)),
      exposes_taken?: html =~ "has already been taken"
    }
  end

  test "renders the registration form (no password to set)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "Create your workspace"
    assert html =~ "Team or company name"
    # Passwordless: the page states up front that a one-time link is emailed.
    assert html =~ "one-time sign-in link"
    refute html =~ ~s|name="user[password]"|
  end

  test "a valid Team choice changes the copy and rides the signup POST", %{conn: conn} do
    token = BillingIntent.sign("team", :year)
    {:ok, lv, html} = live(conn, ~p"/sign_up?billing_intent=#{token}")

    assert html =~ "Selected plan"
    assert html =~ "Annual"
    assert html =~ "Review the price before you pay"
    refute html =~ "Free plan:"
    assert has_element?(lv, ~s(input[name="billing_intent"][value="#{token}"]))
  end

  test "an invalid Team choice falls back to the ordinary Free signup", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/sign_up?billing_intent=forged")

    assert html =~ "Free plan: 3 runners"
    refute html =~ "Selected plan"
    refute has_element?(lv, ~s(input[name="billing_intent"]), "forged")
  end

  test "the landing CTA's ?email= arrives pre-filled, not retyped", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_up?email=founder@example.com")

    assert html =~
             ~r/<input(?=[^>]*\bname="user\[email\]")(?=[^>]*\bvalue="founder@example.com")[^>]*>/
  end

  test "the account-name input is programmatically labelled (UI-005 a11y)", %{conn: conn} do
    # The visible "Team or company name" label is wired to the input via
    # <label for>/id, so a screen reader announces it — the name-based <.input>
    # falls back id → name to keep the association it would otherwise lose.
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    assert has_element?(lv, ~s|label[for="account_name"]|, "Team or company name")
    assert has_element?(lv, ~s|input#account_name[name="account_name"]|)
  end

  test "the registration form carries a CSRF token for its POST to the magic-link start",
       %{conn: conn} do
    # the form's hidden auto-login POST rides the
    # CSRF-protected :browser pipeline. Because it renders with an
    # `action`+`method=post`, `<.form>` emits the hidden `_csrf_token` input, so
    # the legitimate browser submit is accepted and a forged cross-site one is not.
    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "_csrf_token"
    assert html =~ ~s|action="/sign_in/magic/start"|
  end

  test "an already-authenticated visitor is bounced off /sign_up to /app", %{conn: conn} do
    # /sign_up lives under :redirect_if_user_is_authenticated,
    # so a signed-in user is redirected to the app before the LiveView mounts —
    # they have no business on the registration page.
    {conn, _user, _account} = register_and_log_in(conn)

    assert redirected_to(get(conn, ~p"/sign_up")) == ~p"/app"
  end

  test "a valid sign-up creates only the pending user and arms the magic-link POST", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params()

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ ~s|action="/sign_in/magic/start"|
    assert html =~ "phx-trigger-action"

    {:ok, user} = Users.fetch_user_by_email(params["user"]["email"])
    assert [_, handoff] = Regex.run(~r/name="registration_handoff"[^>]*value="([^"]+)"/, html)

    assert RegistrationHandoff.verify(handoff) ==
             {:ok, {user.id, "Founder Co", "Founder Person"}}

    refute user.full_name
    # Email confirmation is a separate step — never auto-confirmed.
    refute user.confirmed_at

    # No account or public slug exists until this inbox proves the exact magic
    # factor; final session minting creates the workspace atomically.
    refute Emisar.Accounts.Membership.Query.not_deleted()
           |> Emisar.Accounts.Membership.Query.by_user_id(user.id)
           |> Emisar.Repo.exists?()

    refute Emisar.Repo.one(Emisar.Accounts.Account)

    assert_error_sent 404, fn ->
      get(build_conn(), ~p"/app/founder-co/sign_in")
    end

    # Signup itself stays quiet: the browser's triggered POST to
    # /sign_in/magic/start is the sole email send for the successful path.
    refute_received {:email, _email}

    requested =
      post(recycle(conn), ~p"/sign_in/magic/start", %{
        "user" => %{"email" => user.email},
        "registration_handoff" => handoff
      })

    assert_received {:email, sent}
    [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
    completed = get(recycle(requested), ~p"/sign_in/magic/#{token_id}/#{secret}")

    assert get_session(completed, :user_token)
    assert %Emisar.Accounts.Account{name: "Founder Co"} = Emisar.Repo.one(Emisar.Accounts.Account)
    assert Emisar.Repo.reload!(user).full_name == "Founder Person"
    assert html_response(get(build_conn(), ~p"/app/founder-co/sign_in"), 200)
  end

  test "an over-long workspace name errors inline and leaves no user behind", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    # A valid user but an over-long workspace name passes the LV's blank check
    # yet fails the account name cap (80) — one transaction, so the user row
    # rolls back with it and the operator fixes the name in place.
    account_name = String.duplicate("x", 81)
    params = sign_up_params(%{"account_name" => account_name})

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ "should be at most 80 character(s)"

    assert html =~
             ~r/<input(?=[^>]*\bname="account_name")(?=[^>]*\bvalue="#{account_name}")[^>]*>/

    assert html =~
             ~r/<input(?=[^>]*\bname="user\[email\]")(?=[^>]*\bvalue="#{params["user"]["email"]}")[^>]*>/

    # Stays on the form: no navigation, and the magic-link POST is never armed.
    refute html =~ "phx-trigger-action"
    assert Users.fetch_user_by_email(params["user"]["email"]) == {:error, :not_found}
  end

  test "a blank workspace name inline-errors and creates nothing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params(%{"account_name" => "  "})

    html = lv |> form("#registration_form", params) |> render_submit()

    # Inline under the field (like every other form), not a flash banner.
    assert html =~ "Tell us what to call your workspace."
    assert Users.fetch_user_by_email(params["user"]["email"]) == {:error, :not_found}
  end

  test "a taken email arms the same neutral magic-link POST without a workspace", %{conn: conn} do
    existing =
      Fixtures.Users.create_user()
      |> Fixtures.Users.set_last_sign_in_at(DateTime.utc_now())

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    params =
      sign_up_params(%{
        "user" => %{"full_name" => "Copy Cat", "email" => existing.email}
      })

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ ~s|action="/sign_in/magic/start"|
    assert html =~ "phx-trigger-action"
    refute html =~ "has already been taken"

    assert [_, handoff] = Regex.run(~r/name="registration_handoff"[^>]*value="([^"]+)"/, html)

    assert {:ok, {decoy_id, "Founder Co", "Copy Cat"}} =
             RegistrationHandoff.verify(handoff)

    refute decoy_id == existing.id

    assert Users.fetch_user_by_email(existing.email) == {:ok, existing}
    refute Emisar.Accounts.Membership.Query.not_deleted() |> Emisar.Repo.one()
  end

  test "new and existing emails return the same triggered response shape", %{conn: conn} do
    existing =
      Fixtures.Users.create_user()
      |> Fixtures.Users.set_last_sign_in_at(DateTime.utc_now())

    new_params = sign_up_params()

    {:ok, new_live, _html} = live(conn, ~p"/sign_up")
    new_html = new_live |> form("#registration_form", new_params) |> render_submit()

    {:ok, existing_live, _html} = live(conn, ~p"/sign_up")

    existing_html =
      existing_live
      |> form(
        "#registration_form",
        sign_up_params(%{
          "user" => %{"full_name" => "Founder Person", "email" => existing.email}
        })
      )
      |> render_submit()

    assert neutral_response_shape(new_html) == neutral_response_shape(existing_html)

    assert neutral_response_shape(new_html) == %{
             posts_to_magic_start?: true,
             triggers_post?: true,
             handoff_fields: 1,
             exposes_taken?: false
           }

    assert [_, new_handoff] =
             Regex.run(~r/name="registration_handoff"[^>]*value="([^"]+)"/, new_html)

    assert [_, existing_handoff] =
             Regex.run(~r/name="registration_handoff"[^>]*value="([^"]+)"/, existing_html)

    assert byte_size(new_handoff) == byte_size(existing_handoff)
    refute new_handoff =~ new_params["user"]["email"]
    refute existing_handoff =~ existing.id
  end

  test "invalid workspace data is identical before the email-existence decision", %{conn: conn} do
    existing = Fixtures.Users.create_user()
    invalid_name = String.duplicate("x", 81)

    for email <- [Fixtures.Random.unique_email(), existing.email] do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")

      html =
        lv
        |> form(
          "#registration_form",
          sign_up_params(%{
            "account_name" => invalid_name,
            "user" => %{"full_name" => "Founder", "email" => email}
          })
        )
        |> render_submit()

      assert html =~ "should be at most 80 character(s)"
      refute html =~ "phx-trigger-action"
      refute html =~ "has already been taken"
    end
  end

  test "the socket submit has an independent per-IP hourly cap", %{conn: conn} do
    Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

    existing =
      Fixtures.Users.create_user()
      |> Fixtures.Users.set_last_sign_in_at(DateTime.utc_now())

    params =
      sign_up_params(%{
        "user" => %{"full_name" => "Existing Person", "email" => existing.email}
      })

    for _ <- 1..20 do
      {:ok, lv, _html} = live(conn, ~p"/sign_up")
      html = lv |> form("#registration_form", params) |> render_submit()
      assert html =~ "phx-trigger-action"
    end

    fresh_email = Fixtures.Random.unique_email()

    fresh_params =
      sign_up_params(%{
        "account_name" => "Rate Limited Workspace",
        "user" => %{"full_name" => "Fresh Person", "email" => fresh_email}
      })

    {:ok, limited_live, _html} = live(conn, ~p"/sign_up")
    limited_html = limited_live |> form("#registration_form", fresh_params) |> render_submit()

    assert limited_html =~ "Too many signup attempts"
    refute limited_html =~ "phx-trigger-action"
    assert Users.fetch_user_by_email(existing.email) == {:ok, existing}
    assert Users.fetch_user_by_email(fresh_email) == {:error, :not_found}
    refute Emisar.Repo.get_by(Emisar.Accounts.Account, name: "Rate Limited Workspace")
    refute_received {:email, _email}
    refute Emisar.Accounts.Membership.Query.not_deleted() |> Emisar.Repo.one()
  end

  test "phx-change validation keeps the typed workspace name", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    html =
      lv
      |> form("#registration_form", sign_up_params(%{"account_name" => "Sticky Name"}))
      |> render_change()

    assert html =~ "Sticky Name"
  end

  test "a malformed email surfaces the regex error inline via phx-change", %{conn: conn} do
    # the email changeset enforces `^[^\s]+@[^\s]+$`, so an
    # address with a space (or no @) re-renders with the inline field error and
    # never submits. The message matches the sign-in form's copy.
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    for bad <- ["foo bar", "nodomain"] do
      html =
        lv
        |> form("#registration_form", sign_up_params(%{"user" => %{"email" => bad}}))
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end
  end

  test "an email past the RFC 5321 maximum inline-errors on the length cap", %{conn: conn} do
    # the shared address validator caps length at 254; a 255-char (otherwise
    # well-formed) address re-renders with the inline max error.
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    long_email = String.duplicate("a", 255 - length(~c"@example.com")) <> "@example.com"
    assert String.length(long_email) == 255

    html =
      lv
      |> form("#registration_form", sign_up_params(%{"user" => %{"email" => long_email}}))
      |> render_change()

    assert html =~ "should be at most 254 byte"
  end

  test "the validate (phx-change) path writes nothing to the DB", %{conn: conn} do
    # the `validate` event runs a pure `change_user` changeset
    # (action :validate) — no insert. Typing the email must never create a user.
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params()

    lv |> form("#registration_form", params) |> render_change()

    assert Users.fetch_user_by_email(params["user"]["email"]) == {:error, :not_found}
  end

  test "an empty full_name is accepted server-side (only the form marks it required)", %{
    conn: conn
  } do
    # `full_name` is cast but NOT validated required in the
    # registration changeset, so a client that strips the `required` attr and
    # submits a blank name still registers (no 500, no inline name error). The
    # form-level `required` is the only guard; this documents that gap explicitly.
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    email = "noname-#{System.unique_integer([:positive])}@example.com"

    params = %{
      "user" => %{"full_name" => "", "email" => email},
      "account_name" => "Nameless Founder Co"
    }

    html = lv |> form("#registration_form", params) |> render_submit()

    # It proceeds to the magic-link POST; the workspace remains deferred until proof.
    assert html =~ ~s|action="/sign_in/magic/start"|
    {:ok, user} = Users.fetch_user_by_email(email)
    assert user.full_name in [nil, ""]
  end
end
