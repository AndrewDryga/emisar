defmodule EmisarWeb.AccountSignInLiveTest do
  @moduledoc """
  The per-account ("branded") sign-in page at `/app/:account_id_or_slug/sign_in`.
  The team is resolved from the slug PRE-AUTH (knowing a slug grants nothing), so
  the load-bearing behaviors are: it offers exactly that account's enabled SSO
  providers, hides the magic-link path when SSO is required, and an
  unknown/soft-deleted slug is an indistinguishable 404 — a signed-out prober
  learns nothing.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Repo
  alias Emisar.SSO.IdentityProvider

  defp enabled_provider(account, name) do
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

  test "offers the account's enabled SSO providers above the email form", %{conn: conn} do
    # enabled providers render as full-redirect buttons
    # (begin is a controller bounce to the IdP, not live nav), and below them the
    # email form posts to the shared magic-link start with a hidden return_to
    # pinning this team.
    account = Fixtures.Accounts.create_account(%{name: "Branded Co"})
    okta = enabled_provider(account, "Acme Okta")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert html =~ "Sign in to Branded Co"
    assert html =~ "Continue with Acme Okta"
    assert html =~ ~p"/sign_in/sso/#{okta.id}"

    # The email form posts to the shared magic-link endpoint and lands back on
    # THIS team via the hidden return_to.
    assert html =~ ~s|action="/sign_in/magic/start"|
    assert html =~ ~s|name="return_to"|
    assert html =~ ~s|value="/app/#{account.slug}"|
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
    assert html =~ "This team requires single sign-on"
    refute html =~ ~s|action="/sign_in/magic/start"|
    refute html =~ "Email me a sign-in link"
  end

  test "the 'different team' link drops to the generic SSO picker", %{conn: conn} do
    # The branded page's only secondary route is "different team", which goes to
    # the generic SSO picker; there's no password/reset link anymore.
    account = Fixtures.Accounts.create_account(%{name: "Threaded Co"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert html =~ ~p"/sign_in/sso"
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
    assert html =~ ~s|action="/sign_in/magic/start"|
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

  test "an already-authenticated visitor is bounced off the branded page", %{conn: conn} do
    # the branded page lives under
    # :redirect_if_user_is_authenticated, so a signed-in user is redirected to /app
    # before the LiveView mounts (they have no business on a sign-in page).
    {conn, _user, account} = register_and_log_in(conn)

    assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/app/#{account}/sign_in")
  end
end
