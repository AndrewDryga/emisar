defmodule EmisarWeb.SSORequiredControllerTest do
  @moduledoc """
  The require_sso step-up must only offer its provider continuation to a
  genuinely non-compliant session — not to anyone who lands
  on the URL from a stale or copied link while their account does not require
  SSO (or their session already satisfies it).
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth

  defmodule StubOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl true
    def begin_authorization(_provider, _opts) do
      {:ok,
       %{
         authorize_url: "https://idp.test/authorize",
         state: "state",
         nonce: "nonce",
         pkce_verifier: "verifier"
       }}
    end

    @impl true
    def verify_callback(_provider, _params, _stash), do: {:error, :access_denied}
  end

  test "starting workspace SSO preserves the initiating browser until proof completes", %{
    conn: conn
  } do
    Emisar.Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
    {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    Fixtures.SSO.create_user_identity(
      account_id: account.id,
      provider_id: provider.id,
      user_id: user.id
    )

    Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
    raw = get_session(conn, :user_token)
    conn = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})

    assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(raw)
    assert get_session(conn, :user_token) == raw
    assert redirected_to(conn) == "https://idp.test/authorize"
  end

  describe "GET /app/:account/sso_required" do
    test "redirects a normal session on an account that does not require SSO", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/#{account}/sso_required")

      assert redirected_to(conn) == ~p"/app/#{account}"
      refute conn.resp_body =~ "requires single sign-on"
    end
  end
end
