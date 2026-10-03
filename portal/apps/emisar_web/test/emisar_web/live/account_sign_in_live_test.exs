defmodule EmisarWeb.AccountSignInLiveTest do
  @moduledoc """
  A workspace's own sign-in page at `/app/:account_id_or_slug/sign_in`. Every
  sign-in targets one workspace, resolved from the slug PRE-AUTH (knowing a slug
  grants nothing), so the load-bearing behaviors are: it offers exactly that
  workspace's enabled SSO providers, its email form posts to that workspace's
  own start, the email path is hidden when the workspace requires SSO, and an
  unknown/soft-deleted slug is an indistinguishable 404 — a signed-out prober
  learns nothing.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Repo
  alias Emisar.SSO.IdentityProvider

  defp enabled_provider(account, name) do
    Fixtures.Accounts.create_subscription(account, "team")

    {:ok, provider} =
      Repo.insert(
        IdentityProvider.Changeset.create(account.id, %{
          kind: :okta,
          name: name,
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true
        })
      )

    provider
  end

  test "offers the workspace's enabled SSO providers above its email form", %{conn: conn} do
    # Enabled providers render as full-redirect buttons (begin is a controller
    # bounce to the IdP, not live nav), and below them the email form posts to
    # this workspace's own start: the path names the workspace.
    account = Fixtures.Accounts.create_account(%{name: "Branded Co"})
    okta = enabled_provider(account, "Acme Okta")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert html =~ "Sign in to Branded Co"
    assert html =~ "Continue with Acme Okta"
    assert html =~ ~p"/sign_in/sso/#{okta.id}"

    assert html =~ ~s|action="/app/#{account.slug}/sign_in/email"|
    assert html =~ "_csrf_token"
    refute html =~ ~s|name="return_to"|
  end

  test "a require_sso account leads with SSO and does not offer magic-link sign-in", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account(%{name: "SSO Only Co"})
    provider = enabled_provider(account, "Acme Okta")
    Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert html =~ "Continue with Acme Okta"
    assert html =~ ~p"/sign_in/sso/#{provider.id}"
    assert html =~ "This workspace requires single sign-on"
    refute html =~ ~s|action="/app/#{account.slug}/sign_in/email"|
    refute html =~ "Send sign-in link"
  end

  test "an expired require_sso account offers recovery by magic link", %{conn: conn} do
    account = Fixtures.Accounts.create_account(%{name: "Recoverable Co"})
    provider = enabled_provider(account, "Dormant Okta")
    Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
    Fixtures.Accounts.create_subscription(account, "team", status: "canceled")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    refute html =~ ~p"/sign_in/sso/#{provider.id}"
    refute html =~ "This workspace requires single sign-on"
    assert html =~ ~s|action="/app/#{account.slug}/sign_in/email"|
    assert html =~ "Send sign-in link"
  end

  test "the 'different workspace' link drops to the workspace picker", %{conn: conn} do
    # The page's only secondary route is "different workspace", which goes to
    # the workspace picker; there's no password/reset link.
    account = Fixtures.Accounts.create_account(%{name: "Threaded Co"})

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert has_element?(lv, ~s(a[href="/sign_in"]), "Sign in to a different workspace")
    refute html =~ "reset_password"
    refute html =~ ~s|name="user[password]"|
  end

  test "an account with zero providers hides the SSO block, showing only the email form", %{
    conn: conn
  } do
    # with no enabled providers the `:if={@providers != []}`
    # SSO section and its separator are absent; the email form is the only
    # offered path.
    account = Fixtures.Accounts.create_account(%{name: "Email Only Co"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    refute html =~ "Continue with"
    refute html =~ "or with email"
    assert html =~ ~s|action="/app/#{account.slug}/sign_in/email"|
  end

  test "a disabled account shows support contact and no authentication controls", %{conn: conn} do
    # owner_subject builds a support subject scoped to the account it creates,
    # which is what set_account_disabled_for_support now requires.
    {_actor, account, support_subject} = Fixtures.Subjects.owner_subject()
    provider = enabled_provider(account, "Paused Okta")

    assert {:ok, _account} =
             Emisar.Accounts.set_account_disabled_for_support(
               account.id,
               true,
               "Temporary hold",
               support_subject
             )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert html =~ "This workspace is disabled"
    assert html =~ "support@emisar.dev"
    refute html =~ ~p"/sign_in/sso/#{provider.id}"
    refute html =~ ~s|action="/app/#{account.slug}/sign_in/email"|
    refute html =~ "Sign in to a different workspace"
  end

  test "an unknown slug is a 404 — and a soft-deleted account is the SAME 404 (no leak)", %{
    conn: conn
  } do
    # `fetch_account_by_id_or_slug`
    # reads `not_deleted()`, so a never-existed slug and a tombstoned account both
    # resolve `:not_found` and raise NotFoundError. A signed-out prober gets an
    # indistinguishable 404 either way and can't confirm a tenant exists.
    assert_error_sent 404, fn -> get(conn, ~p"/app/does-not-exist/sign_in") end

    account = Fixtures.Accounts.create_account(%{name: "Soon Gone Co"})

    {:ok, _} =
      account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

    assert_error_sent 404, fn -> get(conn, ~p"/app/#{account.slug}/sign_in") end
  end

  test "a browser signed in to this workspace goes to it; one signed in elsewhere signs in here",
       %{conn: conn} do
    {conn, _owner, account} = register_and_log_in(conn)
    other = Fixtures.Accounts.create_account(%{name: "Second Co"})

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{account}/sign_in")
    assert to == ~p"/app/#{account}"

    # Another workspace's session is irrelevant here: this one needs its own.
    {:ok, _lv, html} = live(conn, ~p"/app/#{other}/sign_in")
    assert html =~ "Sign in to Second Co"
  end

  test "a signed-in visitor returns to the page that sent it to sign in", %{conn: conn} do
    {conn, _owner, account} = register_and_log_in(conn)

    conn =
      conn
      |> init_test_session(%{user_return_to: ~p"/app/#{account}/runs"})
      |> get(~p"/app/#{account}/sign_in")

    assert redirected_to(conn) == ~p"/app/#{account}/runs"
    refute get_session(conn, :user_return_to)
  end

  test "a dead entry for this workspace leaves the cookie and the page renders", %{conn: conn} do
    {conn, _owner, account} = register_and_log_in(conn)
    Fixtures.Auth.delete_session_token!(session_token(conn, account))

    rendered = get(conn, ~p"/app/#{account}/sign_in")

    assert html_response(rendered, 200) =~ "Sign in to Test Co"
    assert get_session(rendered, :sessions) == nil
  end
end
