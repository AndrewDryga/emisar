defmodule EmisarWeb.UserSignUpLiveTest do
  @moduledoc """
  Self-serve sign-up (plan §3 "Sign-up"): the form validates the owner's name
  and address and the workspace's name, then arms its POST to `/sign_up`, which
  sends the code and keeps the intent server-side. Nothing — no workspace,
  Member or slug — exists until that code comes back in this browser
  (`UserSessionControllerTest` drives the completion).
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Accounts.Membership
  alias Emisar.Repo
  alias EmisarWeb.BillingIntent

  defp sign_up_params(overrides \\ %{}) do
    %{
      "sign_up" =>
        Map.merge(
          %{
            "full_name" => "Founder Person",
            "email" => "founder-#{System.unique_integer([:positive])}@example.com",
            "account_name" => "Founder Co #{System.unique_integer([:positive])}"
          },
          overrides
        )
    }
  end

  defp members_with_email(email),
    do: Membership.Query.all() |> Membership.Query.by_email(email) |> Repo.all()

  test "renders the sign-up form, posting to /sign_up with a CSRF token", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "Create your workspace"
    assert html =~ "Workspace name"
    # Passwordless: the page states up front that a one-time link is emailed.
    assert html =~ "one-time sign-in link"
    refute html =~ "password"
    assert html =~ ~s|action="/sign_up"|
    assert html =~ "_csrf_token"
  end

  test "a valid Team choice changes the copy and rides the sign-up POST", %{conn: conn} do
    token = BillingIntent.sign("team", :year)
    {:ok, lv, html} = live(conn, ~p"/sign_up?billing_intent=#{token}")

    assert html =~ "Selected plan"
    assert html =~ "Annual"
    assert html =~ "Review the price before you pay"
    refute html =~ "Free plan:"
    assert has_element?(lv, ~s(input[name="billing_intent"][value="#{token}"]))
  end

  test "an invalid Team choice falls back to the ordinary Free sign-up", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/sign_up?billing_intent=forged")

    assert html =~ "Free plan: 3 runners"
    refute html =~ "Selected plan"
    refute has_element?(lv, ~s(input[name="billing_intent"]))
  end

  test "the landing CTA's ?email= arrives pre-filled, not retyped", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up?email=founder@example.com")

    assert has_element?(lv, ~s|input[name="sign_up[email]"][value="founder@example.com"]|)
  end

  test "the workspace-name input is programmatically labelled", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    assert has_element?(lv, ~s|label[for="sign_up_account_name"]|, "Workspace name")
    assert has_element?(lv, ~s|input#sign_up_account_name[name="sign_up[account_name]"]|)
  end

  test "a signed-in browser can still create another workspace", %{conn: conn} do
    {conn, _owner, _account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/sign_up")
    assert html =~ "Create your workspace"
  end

  test "a valid submission arms the POST, which sends the code and creates nothing", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params()
    email = params["sign_up"]["email"]

    form = form(lv, "#registration_form", params)
    assert render_submit(form) =~ "phx-trigger-action"
    refute_received {:email, _code}

    posted = follow_trigger_action(form, conn)

    assert posted.request_path == ~p"/sign_up"
    assert redirected_to(posted) == ~p"/sign_in/magic?sent=1"
    assert_received {:email, %{to: [{_name, ^email}]}}
    # Nothing exists until the code comes back in this browser.
    assert members_with_email(email) == []
  end

  test "an over-long workspace name errors inline, keeps the input and arms nothing", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    account_name = String.duplicate("x", 81)
    params = sign_up_params(%{"account_name" => account_name})

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ "should be at most 80 character(s)"
    assert has_element?(lv, ~s|input[name="sign_up[account_name]"][value="#{account_name}"]|)

    assert has_element?(
             lv,
             ~s|input[name="sign_up[email]"][value="#{params["sign_up"]["email"]}"]|
           )

    refute html =~ "phx-trigger-action"
  end

  test "a blank workspace name errors inline and arms nothing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    html =
      lv
      |> form("#registration_form", sign_up_params(%{"account_name" => "  "}))
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    refute html =~ "phx-trigger-action"
  end

  test "an address already a Member somewhere signs up like any other address", %{conn: conn} do
    # Emails are not global: being a Member of another workspace, invited to
    # one, or provisioned by a directory hides nothing at sign-up.
    {conn_owner, owner, _account} = register_and_log_in(build_conn())
    assert conn_owner

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    html =
      lv
      |> form("#registration_form", sign_up_params(%{"email" => owner.email}))
      |> render_submit()

    assert html =~ "phx-trigger-action"
    refute html =~ "has already been taken"
  end

  test "phx-change keeps the typed workspace name and writes nothing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params(%{"account_name" => "Sticky Name"})

    html = lv |> form("#registration_form", params) |> render_change()

    assert html =~ "Sticky Name"
    assert members_with_email(params["sign_up"]["email"]) == []
  end

  test "a malformed email surfaces the address error inline via phx-change", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    for bad <- ["foo bar", "nodomain"] do
      html =
        lv
        |> form("#registration_form", sign_up_params(%{"email" => bad}))
        |> render_change()

      assert html =~ "must have the @ sign and no spaces"
    end
  end

  test "an email past the RFC 5321 maximum errors inline on the length cap", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    long_email = String.duplicate("a", 255 - length(~c"@example.com")) <> "@example.com"
    assert String.length(long_email) == 255

    html =
      lv
      |> form("#registration_form", sign_up_params(%{"email" => long_email}))
      |> render_change()

    assert html =~ "should be at most 254 byte"
  end

  test "an empty name is accepted (only the form marks it required)", %{conn: conn} do
    # `full_name` is optional in `Accounts.SignUpInput`, so a client that strips
    # the `required` attribute still signs up; the owner then has no name.
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    html =
      lv
      |> form("#registration_form", sign_up_params(%{"full_name" => ""}))
      |> render_submit()

    assert html =~ "phx-trigger-action"
  end
end
