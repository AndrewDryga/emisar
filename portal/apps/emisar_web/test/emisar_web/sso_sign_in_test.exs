defmodule EmisarWeb.SSOSignInTest do
  @moduledoc """
  Signed-out SSO sign-in routes by SLUG, not email domain: the team picker
  (`/sign_in/sso`) sends the operator to their team's branded sign-in page
  (`/app/:slug/sign_in`), which offers that account's SSO providers plus
  email/password and the magic link. An out-of-domain member, guest, or
  contractor signs in the same way as anyone else.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Fixtures, Repo}
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

  describe "GET /sign_in/sso (team picker)" do
    test "renders the team-address form, not the old email-domain field", %{conn: conn} do
      html = conn |> get(~p"/sign_in/sso") |> html_response(200)

      assert html =~ "Sign in with SSO"
      assert html =~ "Which team are you signing in to"
      refute html =~ "Work email"
    end
  end

  describe "POST /sign_in/sso (team picker)" do
    test "a known team address routes to that team's branded sign-in page", %{conn: conn} do
      account = Fixtures.account_fixture()

      conn = post(conn, ~p"/sign_in/sso", team: %{slug: account.slug})
      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
    end

    test "an unknown team address re-renders with an error, no redirect", %{conn: conn} do
      conn = post(conn, ~p"/sign_in/sso", team: %{slug: "no-such-team"})
      assert html_response(conn, 200) =~ "couldn&#39;t find a team"
    end
  end

  describe "GET /app/:account_id_or_slug/sign_in (branded page)" do
    test "offers the account's enabled SSO providers AND email/password (decision 4)", %{
      conn: conn
    } do
      account = Fixtures.account_fixture()
      provider = enabled_provider(account, "Acme Okta")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

      assert html =~ "Sign in to #{account.name}"
      assert html =~ "Continue with #{provider.name}"
      # Links to that provider's begin-auth redirect…
      assert html =~ ~p"/sign_in/sso/#{provider.id}"
      # …and the page still offers email/password + the magic link.
      assert html =~ "Password"
      assert html =~ ~p"/sign_in/magic"
    end

    test "resolves by the account id too (the UUID form)", %{conn: conn} do
      account = Fixtures.account_fixture()
      assert {:ok, _lv, html} = live(conn, ~p"/app/#{account.id}/sign_in")
      assert html =~ "Sign in to #{account.name}"
    end

    test "an unknown team slug 404s", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/app/no-such-team/sign_in") end
    end
  end

  describe "branded sign-in lands on that team" do
    test "email/password carrying the branded page's return_to lands on that team", %{conn: conn} do
      {_conn, user, account} = register_and_log_in(conn)

      # A fresh (signed-out) sign-in posting the branded page's hidden return_to.
      conn =
        post(build_conn(), ~p"/sign_in",
          user: %{
            "email" => user.email,
            "password" => "very-long-password-here",
            "return_to" => ~p"/app/#{account}"
          }
        )

      assert redirected_to(conn) == ~p"/app/#{account}"
    end

    test "a forged non-local return_to is ignored — no open redirect", %{conn: conn} do
      {_conn, user, _account} = register_and_log_in(conn)

      conn =
        post(build_conn(), ~p"/sign_in",
          user: %{
            "email" => user.email,
            "password" => "very-long-password-here",
            "return_to" => "https://evil.test/phish"
          }
        )

      # Falls back to the default landing (bare /app → the user's account), never
      # the external URL.
      assert redirected_to(conn) == ~p"/app"
      refute redirected_to(conn) =~ "evil.test"
    end
  end
end
