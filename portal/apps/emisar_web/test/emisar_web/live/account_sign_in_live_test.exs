defmodule EmisarWeb.AccountSignInLiveTest do
  @moduledoc """
  The per-account ("branded") sign-in page at `/app/:account_id_or_slug/sign_in`.
  The team is resolved from the slug PRE-AUTH (knowing a slug grants nothing), so
  the load-bearing behaviors are: it offers exactly that account's enabled SSO
  providers plus the shared email+password path, and an unknown/soft-deleted slug
  is an indistinguishable 404 — a signed-out prober learns nothing.
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

  test "offers the account's enabled SSO providers above the userpass form", %{conn: conn} do
    # closes AUTH-007-T01 — enabled providers render as full-redirect buttons
    # (begin is a controller bounce to the IdP, not live nav), and below them the
    # email+password form posts to the shared /sign_in with a hidden return_to
    # pinning this team.
    account = Emisar.Fixtures.account_fixture(%{name: "Branded Co"})
    okta = enabled_provider(account, "Acme Okta")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert html =~ "Sign in to Branded Co"
    assert html =~ "Continue with Acme Okta"
    assert html =~ ~p"/sign_in/sso/#{okta.id}"

    # Userpass form posts to the shared endpoint and lands back on THIS team.
    assert html =~ ~s|action="/sign_in"|
    assert html =~ ~s|name="user[return_to]"|
    assert html =~ ~s|value="/app/#{account.slug}"|
  end

  test "the forgot-password and magic links thread this team's return_to", %{conn: conn} do
    # closes AUTH-007-T03 — both secondary routes carry ?return_to=/app/<slug> so a
    # password reset or magic link begun here lands back on the branded page, while
    # "different team" drops to the generic SSO picker.
    account = Emisar.Fixtures.account_fixture(%{name: "Threaded Co"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    assert html =~ ~p"/reset_password?#{[return_to: "/app/#{account.slug}"]}"
    assert html =~ ~p"/sign_in/magic?#{[return_to: "/app/#{account.slug}"]}"
    assert html =~ ~p"/sign_in/sso"
  end

  test "an account with zero providers hides the SSO block, showing only userpass", %{conn: conn} do
    # closes AUTH-007-T04 — with no enabled providers the `:if={@providers != []}`
    # SSO section and its separator are absent; the email+password form is the only
    # offered path.
    account = Emisar.Fixtures.account_fixture(%{name: "Password Only Co"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

    refute html =~ "Continue with"
    refute html =~ "or with email"
    assert html =~ ~s|id="login_form"|
  end

  test "an unknown slug is a 404 — and a soft-deleted account is the SAME 404 (no leak)", %{
    conn: conn
  } do
    # closes AUTH-007-T05, AUTH-007-T06, AUTH-007-T08 — `fetch_account_by_id_or_slug`
    # reads `not_deleted()`, so a never-existed slug and a tombstoned account both
    # resolve `:not_found` and raise NotFoundError. A signed-out prober gets an
    # indistinguishable 404 either way and can't confirm a tenant exists.
    assert_error_sent 404, fn -> get(conn, ~p"/app/does-not-exist/sign_in") end

    account = Emisar.Fixtures.account_fixture(%{name: "Soon Gone Co"})

    {:ok, _} =
      account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

    assert_error_sent 404, fn -> get(conn, ~p"/app/#{account.slug}/sign_in") end
  end

  test "an already-authenticated visitor is bounced off the branded page", %{conn: conn} do
    # closes AUTH-007-T09 — the branded page lives under
    # :redirect_if_user_is_authenticated, so a signed-in user is redirected to /app
    # before the LiveView mounts (they have no business on a sign-in page).
    {conn, _user, account} = register_and_log_in(conn)

    assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/app/#{account}/sign_in")
  end
end
