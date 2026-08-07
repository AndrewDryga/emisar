defmodule EmisarWeb.UserSignUpLiveTest do
  @moduledoc """
  Self-serve sign-up: one form creates the user AND their free-plan
  workspace, then arms the hidden POST that mails the one-time sign-in
  link. Passwordless — no credential is set at registration, and the magic-link
  round-trip is the email-confirmation path.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Users
  alias EmisarWeb.RegistrationHandoff

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

  test "renders the registration form (no password to set)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "Start your free workspace"
    assert html =~ "Team or company name"
    # Passwordless: the page states up front that a one-time link is emailed.
    assert html =~ "one-time sign-in link"
    refute html =~ ~s|name="user[password]"|
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

  test "a valid sign-up creates user + workspace and arms the magic-link POST", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params()

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ ~s|action="/sign_in/magic/start"|
    assert html =~ "phx-trigger-action"

    {:ok, user} = Users.fetch_user_by_email(params["user"]["email"])
    assert [_, handoff] = Regex.run(~r/name="registration_handoff"[^>]*value="([^"]+)"/, html)
    assert RegistrationHandoff.verify(handoff) == {:ok, user.id}

    assert user.full_name == "Founder Person"
    # Email confirmation is a separate step — never auto-confirmed.
    refute user.confirmed_at

    memberships =
      Emisar.Accounts.Membership.Query.not_deleted()
      |> Emisar.Accounts.Membership.Query.by_user_id(user.id)
      |> Emisar.Repo.all()
      |> Emisar.Repo.preload(:account)

    assert [%{role: :owner, account: %{name: "Founder Co"}}] = memberships

    # Signup itself stays quiet: the browser's triggered POST to
    # /sign_in/magic/start is the sole email send for the successful path.
    refute_received {:email, _email}
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

  test "a taken email renders the changeset error inline", %{conn: conn} do
    existing = Fixtures.Users.create_user()

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    params =
      sign_up_params(%{
        "user" => %{"full_name" => "Copy Cat", "email" => existing.email}
      })

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ "has already been taken"
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

    assert html =~ "should be at most 254 character"
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

    # It proceeds to the magic-link POST — the workspace was created, no crash.
    assert html =~ ~s|action="/sign_in/magic/start"|
    {:ok, user} = Users.fetch_user_by_email(email)
    assert user.full_name in [nil, ""]
  end
end
