defmodule EmisarWeb.RequireSSOTest do
  @moduledoc """
  Per-account `require_sso` (enforcement approach B): a member must hold an SSO
  session FOR THIS ACCOUNT to reach it. A magic-link session — or an SSO
  session for a *different* account — is logged out and sent to this account's
  branded SSO sign-in. The owner-only toggle can't be turned on without an enabled
  SSO connection (no lock-out).
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Repo
  alias Emisar.SSO.{IdentityProvider, UserIdentity}

  defp enabled_provider(account) do
    {:ok, provider} =
      Repo.insert(
        IdentityProvider.Changeset.create(account.id, %{
          kind: :okta,
          name: "Acme Okta",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true
        })
      )

    provider
  end

  defp require_sso!(account),
    do: Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

  # A real signed-in session whose token records SSO provenance for `identity`.
  defp sso_session(user, identity) do
    token =
      Emisar.Auth.create_session_token!(user, :sso, true, %{}, user_identity_id: identity.id)

    build_conn() |> init_test_session(%{}) |> put_session(:user_token, token)
  end

  defp identity_for(account, provider, user) do
    {:ok, identity} =
      Repo.insert(
        UserIdentity.Changeset.create(account.id, provider.id, user.id, %{
          provider_identifier: "okta|#{System.unique_integer([:positive])}",
          created_by: :provider,
          provisioned_via: :oidc_jit
        })
      )

    identity
  end

  describe "enforcement" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "require_sso OFF — a magic-link session reaches the account", %{
      conn: conn,
      account: account
    } do
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
    end

    test "require_sso ON — a magic-link session is bounced to the SSO step-up", %{
      conn: conn,
      account: account
    } do
      _ = enabled_provider(account)
      require_sso!(account)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{account}/runners")
      assert to == ~p"/app/#{account}/sso_required"
    end

    test "require_sso ON — an SSO session FOR THIS ACCOUNT reaches it", %{
      user: user,
      account: account
    } do
      provider = enabled_provider(account)
      require_sso!(account)
      identity = identity_for(account, provider, user)

      assert {:ok, _lv, _html} = live(sso_session(user, identity), ~p"/app/#{account}/runners")
    end

    test "require_sso ON — an SSO session for a DIFFERENT account is still bounced", %{
      user: user,
      account: account
    } do
      # This account HAS a usable connection (so the gate is live, not failing open)…
      _ = enabled_provider(account)
      require_sso!(account)

      # …but the user's SSO identity belongs to some OTHER account, not this one.
      {_c2, _u2, other} = register_and_log_in(build_conn())
      other_provider = enabled_provider(other)
      foreign_identity = identity_for(other, other_provider, user)

      assert {:error, {:redirect, %{to: to}}} =
               live(sso_session(user, foreign_identity), ~p"/app/#{account}/runners")

      assert to == ~p"/app/#{account}/sso_required"
    end

    test "require_sso ON — a magic-link session is bounced (only :sso provenance passes)", %{
      user: user,
      account: account
    } do
      # `ensure_sso_compliant` admits ONLY an `:sso` session
      # for this account. A magic-link session (auth_method :magic_link) is not an
      # SSO one, so it's bounced to the step-up shim even though the operator
      # authenticated — the account demands the IdP specifically.
      _ = enabled_provider(account)
      require_sso!(account)

      magic_token = Emisar.Auth.create_session_token!(user, :magic_link, false)

      magic_conn =
        build_conn() |> init_test_session(%{}) |> put_session(:user_token, magic_token)

      assert {:error, {:redirect, %{to: to}}} = live(magic_conn, ~p"/app/#{account}/runners")
      assert to == ~p"/app/#{account}/sso_required"
    end

    test "require_sso ON with NO enabled connection — fails OPEN, not a brick", %{
      conn: conn,
      account: account
    } do
      require_sso!(account)

      # No enabled provider exists, so the gate can't ever be satisfied — it fails
      # OPEN rather than locking everyone out (the provider write paths prevent
      # reaching this via the UI; this covers an out-of-band removal). Recoverable.
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
    end
  end

  describe "the step-up shim (/sso_required)" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      require_sso!(account)
      %{conn: conn, account: account}
    end

    test "logs the session out and lands on the account's branded sign-in", %{
      conn: conn,
      account: account
    } do
      conn = get(conn, ~p"/app/#{account}/sso_required")

      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
      refute get_session(conn, :user_token)
    end

    test "the shim flashes the SSO-required explanation", %{conn: conn, account: account} do
      # the step-up shim doesn't bounce silently: it logs out
      # with a flash naming the cause, so the operator understands why they were
      # signed out and what to do (sign in with the IdP) rather than seeing a bare
      # sign-in page.
      conn = get(conn, ~p"/app/#{account}/sso_required")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "requires single sign-on"
    end
  end

  describe "the owner toggle" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "owner turns it on when an enabled SSO connection exists", %{
      conn: conn,
      account: account
    } do
      _ = enabled_provider(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      render_click(lv, "toggle_require_sso", %{})

      assert Repo.reload!(account).settings.require_sso
    end

    test "owner cannot turn it on with no connection — flashed, no change (handler guards too)",
         %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      html = render_click(lv, "toggle_require_sso", %{})

      assert html =~ "Add an enabled SSO connection"
      refute Repo.reload!(account).settings.require_sso
    end

    test "a viewer cannot toggle it", %{account: account} do
      _ = enabled_provider(account)
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/settings/team")

      html = render_click(lv, "toggle_require_sso", %{})

      assert html =~ "Only owners and admins"
      refute Repo.reload!(account).settings.require_sso
    end
  end
end
