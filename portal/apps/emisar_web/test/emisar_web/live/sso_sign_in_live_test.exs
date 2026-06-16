defmodule EmisarWeb.SSOSignInLiveTest do
  @moduledoc """
  The signed-out SSO entry page: a work-email field that routes a known email
  domain to its provider's begin-auth redirect, and shows a clear message for
  a domain with no connection. The lookup is pre-auth (no Subject) — it IS the
  start of authentication.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Fixtures, Repo}
  alias Emisar.SSO.IdentityProvider

  defp enabled_provider_for_domain(domain) do
    {_user, account, _subject} = Fixtures.owner_subject_fixture(%{plan: "enterprise"})

    {:ok, provider} =
      Repo.insert(
        IdentityProvider.Changeset.create(account.id, %{
          kind: :okta,
          name: "Acme Okta",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          allowed_email_domain: domain,
          enabled: true
        })
      )

    provider
  end

  describe "GET /sign_in/sso" do
    test "renders the work-email form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in/sso")

      assert html =~ "Single sign-on"
      assert html =~ "Work email"
    end

    test "a known email domain redirects to that provider's begin-auth", %{conn: conn} do
      provider = enabled_provider_for_domain("acme.test")
      {:ok, lv, _html} = live(conn, ~p"/sign_in/sso")

      assert {:error, {:redirect, %{to: to}}} =
               lv
               |> form("#sso_form", %{"sso" => %{"email" => "person@acme.test"}})
               |> render_submit()

      assert to == ~p"/sign_in/sso/#{provider.id}"
    end

    test "an unknown email domain shows the no-SSO message", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/sso")

      html =
        lv
        |> form("#sso_form", %{"sso" => %{"email" => "person@nowhere.test"}})
        |> render_submit()

      assert html =~ "No single sign-on is configured for that email domain."
    end

    test "an @-less entry is rejected without querying", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/sso")

      html =
        lv
        |> form("#sso_form", %{"sso" => %{"email" => "not-an-email"}})
        |> render_submit()

      assert html =~ "Enter a work email"
    end
  end
end
