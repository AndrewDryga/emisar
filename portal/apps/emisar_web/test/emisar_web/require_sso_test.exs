defmodule EmisarWeb.RequireSSOTest do
  @moduledoc """
  Per-account `require_sso` (enforcement approach B): a member must hold an SSO
  session FOR THIS ACCOUNT to reach it. A password/magic session — or an SSO
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
    do: account |> Ecto.Changeset.change(require_sso: true) |> Repo.update!()

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
    test "require_sso OFF — a password session reaches the account", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
    end

    test "require_sso ON — a password session is bounced to the SSO step-up", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      require_sso!(account)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{account}/runners")
      assert to == ~p"/app/#{account}/sso_required"
    end

    test "require_sso ON — an SSO session FOR THIS ACCOUNT reaches it", %{conn: conn} do
      {_conn, user, account} = register_and_log_in(conn)
      provider = enabled_provider(account)
      require_sso!(account)
      identity = identity_for(account, provider, user)

      assert {:ok, _lv, _html} = live(sso_session(user, identity), ~p"/app/#{account}/runners")
    end

    test "require_sso ON — an SSO session for a DIFFERENT account is still bounced", %{conn: conn} do
      {_conn, user, account} = register_and_log_in(conn)
      require_sso!(account)

      # The user's SSO identity belongs to some OTHER account, not this one.
      {_c2, _u2, other} = register_and_log_in(build_conn())
      other_provider = enabled_provider(other)
      foreign_identity = identity_for(other, other_provider, user)

      assert {:error, {:redirect, %{to: to}}} =
               live(sso_session(user, foreign_identity), ~p"/app/#{account}/runners")

      assert to == ~p"/app/#{account}/sso_required"
    end
  end

  describe "the step-up shim (/sso_required)" do
    test "logs the session out and lands on the account's branded sign-in", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      require_sso!(account)

      conn = get(conn, ~p"/app/#{account}/sso_required")

      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
      refute get_session(conn, :user_token)
    end
  end

  describe "the owner toggle" do
    test "owner turns it on when an enabled SSO connection exists", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      _ = enabled_provider(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      render_click(lv, "toggle_require_sso", %{})

      assert Repo.reload!(account).require_sso
    end

    test "owner cannot turn it on with no connection — flashed, no change (handler guards too)",
         %{
           conn: conn
         } do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      html = render_click(lv, "toggle_require_sso", %{})

      assert html =~ "Add an enabled SSO connection"
      refute Repo.reload!(account).require_sso
    end

    test "a viewer cannot toggle it", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)
      _ = enabled_provider(account)
      viewer = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/settings/team")

      html = render_click(lv, "toggle_require_sso", %{})

      assert html =~ "Only the account owner"
      refute Repo.reload!(account).require_sso
    end
  end
end
