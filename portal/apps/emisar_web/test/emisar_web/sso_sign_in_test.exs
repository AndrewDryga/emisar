defmodule EmisarWeb.SSOSignInTest do
  @moduledoc """
  Signed-out SSO sign-in routes by SLUG, not email domain: the team picker
  (`/sign_in/sso`) sends the operator to their team's branded sign-in page
  (`/app/:slug/sign_in`), which offers that account's SSO providers plus
  the passwordless magic link. An out-of-domain member, guest, or
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

  # Drive the real passwordless sign-in carrying a branded `return_to`: request
  # the link (threading return_to onto both the session and the emailed URL), pull
  # token_id + the 6-character secret out of the email, then confirm the link from the
  # same browser (the nonce cookie rides `recycle`). Returns the post-confirm conn.
  defp magic_sign_in(email, return_to) do
    conn =
      post(build_conn(), ~p"/sign_in/magic/start", %{
        "user" => %{"email" => email},
        "return_to" => return_to
      })

    assert_received {:email, sent}
    [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

    recycle(conn)
    |> get(~p"/sign_in/magic/#{token_id}/#{secret}?#{[return_to: return_to]}")
  end

  describe "GET /sign_in/sso (team picker)" do
    test "renders the team-address form, not the old email-domain field", %{conn: conn} do
      html = conn |> get(~p"/sign_in/sso") |> html_response(200)

      assert html =~ "Sign in with SSO"
      assert html =~ "Which team are you signing in to"
      refute html =~ "Work email"
    end

    test "a returning browser's recent-team button shows the slug, not just the name", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()

      # secret_key_base is needed to sign the recent-accounts cookie; a bare test
      # conn doesn't carry it until it's been through the endpoint.
      html =
        conn
        |> Map.put(:secret_key_base, EmisarWeb.Endpoint.config(:secret_key_base))
        |> EmisarWeb.RecentAccounts.put(%{slug: account.slug, name: account.name})
        # Carry the just-written response cookie back as a request cookie.
        |> recycle()
        |> get(~p"/sign_in/sso")
        |> html_response(200)

      assert html =~ account.name
      # The slug sub-label disambiguates teams with similar names + teaches the URL form.
      assert html =~ "app/#{account.slug}"
    end
  end

  describe "POST /sign_in/sso (team picker)" do
    test "a known team address routes to that team's branded sign-in page", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      conn = post(conn, ~p"/sign_in/sso", team: %{slug: account.slug})
      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
    end

    test "an unknown team address re-renders with an error, no redirect", %{conn: conn} do
      conn = post(conn, ~p"/sign_in/sso", team: %{slug: "no-such-team"})
      assert html_response(conn, 200) =~ "couldn&#39;t find a team"
    end

    test "a whitespace-only slug trims to nothing and re-renders the not-found message", %{
      conn: conn
    } do
      # the controller `String.trim`s the slug before looking
      # it up, so "   " becomes "" which no account matches: the same friendly
      # not-found re-render as a real unknown slug, never a redirect or a crash.
      conn = post(conn, ~p"/sign_in/sso", team: %{slug: "   "})
      assert html_response(conn, 200) =~ "couldn&#39;t find a team"
    end

    test "malformed team fields re-render the neutral not-found response", %{conn: conn} do
      for params <- [
            %{"team" => %{"slug" => %{"nested" => "value"}}},
            %{"team" => "not-a-map"},
            %{}
          ] do
        response = post(conn, ~p"/sign_in/sso", params)

        assert html_response(response, 200) =~ "couldn&#39;t find a team"
      end
    end

    test "a real slug and a fake slug resolve through the same pre-auth lookup — no leak", %{
      conn: conn
    } do
      # both a real and a bogus team address go through the
      # same Subject-less `fetch_account_by_id_or_slug`. A real slug redirects to its
      # branded sign-in; an unknown one re-renders the friendly "couldn't find a team"
      # (200, no redirect). The signed-out prober learns only "this slug routes
      # somewhere" vs "not found" — never anything an account holder's session would
      # reveal, and knowing a slug grants nothing (the branded page is public).
      account = Fixtures.Accounts.create_account()

      real = post(conn, ~p"/sign_in/sso", team: %{slug: account.slug})
      assert redirected_to(real) == ~p"/app/#{account}/sign_in"

      fake = post(conn, ~p"/sign_in/sso", team: %{slug: "definitely-not-a-team"})
      assert fake.status == 200
      assert html_response(fake, 200) =~ "couldn&#39;t find a team"
    end

    test "a tampered recent-accounts cookie is ignored — at worst an empty picker, no crash", %{
      conn: conn
    } do
      # the recent-accounts cookie is SIGNED, so a forged value
      # fails verification and is dropped (`list/1` → []): the picker renders its
      # manual-slug empty state rather than trusting attacker-planted entries or
      # crashing. (Even a validly-signed cookie only carries slug+name — never
      # secrets — so the worst case is surfacing a team the browser already chose.)
      conn =
        conn
        |> Map.put(:secret_key_base, EmisarWeb.Endpoint.config(:secret_key_base))
        |> Plug.Test.put_req_cookie("emisar_recent_accounts", "not-a-validly-signed-cookie")

      html = conn |> get(~p"/sign_in/sso") |> html_response(200)

      # Renders the picker (manual team-address form) without error.
      assert html =~ "Which team are you signing in to"
    end

    test "an already-authenticated visitor is bounced off the team picker to /app", %{conn: conn} do
      # a signed-in user has no business on the
      # signed-out "which team?" picker render; `:redirect_if_user_is_authenticated`
      # bounces them to the app before the controller runs.
      {conn, _user, _account} = register_and_log_in(conn)

      assert redirected_to(get(conn, ~p"/sign_in/sso")) == ~p"/app"
    end

    test "an already-authenticated visitor's team-resolve POST is bounced to /app", %{conn: conn} do
      # the resolve-team POST shares the guarded scope, so a
      # signed-in user can't drive the picker to a branded page; the gate halts
      # before the controller resolves any slug.
      {conn, _user, _account} = register_and_log_in(conn)

      conn = post(conn, ~p"/sign_in/sso", team: %{slug: "any-team"})
      assert redirected_to(conn) == ~p"/app"
    end
  end

  describe "GET /app/:account_id_or_slug/sign_in (branded page)" do
    test "offers the account's enabled SSO providers AND the magic-link email form", %{
      conn: conn
    } do
      account = Fixtures.Accounts.create_account()
      provider = enabled_provider(account, "Acme Okta")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

      assert html =~ "Sign in to #{account.name}"
      assert html =~ "Continue with #{provider.name}"
      # Links to that provider's begin-auth redirect…
      assert html =~ ~p"/sign_in/sso/#{provider.id}"
      # …and the page offers the passwordless email form, posting to the shared
      # magic-link start with a hidden return_to pinning this team so the flow
      # lands back here, not on the user's stale default.
      assert html =~ ~s|action="/sign_in/magic/start"|
      assert html =~ ~s|value="/app/#{account.slug}"|
      refute html =~ "Password"
    end

    test "resolves by the account id too (the UUID form)", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      assert {:ok, _lv, html} = live(conn, ~p"/app/#{account.id}/sign_in")
      assert html =~ "Sign in to #{account.name}"
    end

    test "an unknown team slug 404s", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/app/no-such-team/sign_in") end
    end

    test "an already-authenticated visitor is bounced off the branded page to /app", %{conn: conn} do
      # the branded sign-in lives under
      # `:redirect_if_user_is_authenticated`, so a signed-in user GETting any
      # team's branded page is redirected to the app before the LiveView mounts —
      # no second sign-in surface for someone already signed in.
      {conn, _user, account} = register_and_log_in(conn)

      assert redirected_to(get(conn, ~p"/app/#{account}/sign_in")) == ~p"/app"
    end
  end

  describe "branded sign-in lands on that team" do
    setup %{conn: conn} do
      {_conn, user, account} = register_and_log_in(conn)
      %{user: user, account: account}
    end

    test "a member's branded magic-link sign-in lands on that team", %{
      user: user,
      account: account
    } do
      conn = magic_sign_in(user.email, ~p"/app/#{account}")

      assert redirected_to(conn) == ~p"/app/#{account}"
    end

    test "a member's branded sign-in is remembered (recent-accounts cookie written)", %{
      user: user,
      account: account
    } do
      conn = magic_sign_in(user.email, ~p"/app/#{account}")

      assert redirected_to(conn) == ~p"/app/#{account}"
      # So the next sign-in offers this team as a one-click button.
      assert Map.has_key?(conn.resp_cookies, "emisar_recent_accounts")
    end

    test "a non-member's branded sign-in lands on their default account, not a 404", %{user: user} do
      # A team the user has no membership in (so the branded return_to would 404).
      other = Fixtures.Accounts.create_account()

      conn = magic_sign_in(user.email, ~p"/app/#{other}")

      # The branded target is dropped → default landing, never a post-login 404.
      assert redirected_to(conn) == ~p"/app"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "don't have access"
      # And the team they can't reach is NOT remembered.
      refute Map.has_key?(conn.resp_cookies, "emisar_recent_accounts")
    end

    test "a forged non-local return_to is ignored — no open redirect", %{user: user} do
      conn = magic_sign_in(user.email, "https://evil.test/phish")

      # Falls back to the default landing (bare /app → the user's account), never
      # the external URL.
      assert redirected_to(conn) == ~p"/app"
      refute redirected_to(conn) =~ "evil.test"
    end
  end
end
