defmodule EmisarWeb.OAuthControllerTest do
  @moduledoc """
  HTTP surface of the OAuth 2.1 authorization server: discovery
  metadata, Dynamic Client Registration, the consent screen, the token
  endpoint, and the resulting `emo-` access token working against the
  MCP JSON-RPC endpoint (with RFC 9728 `WWW-Authenticate` on 401).
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Fixtures, OAuth}

  @redirect "https://claude.ai/api/mcp/auth_callback"
  @resource "https://app.emisar.dev/api/mcp/rpc"

  setup do
    {user, account, _subject} = Fixtures.owner_subject_fixture()
    %{user: user, account: account}
  end

  defp register_client!(name \\ "Claude") do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => name, "redirect_uris" => [@redirect]})

    client
  end

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  # Mint a live access token end-to-end through the context (the browser
  # consent step is covered separately).
  defp mint_access_token(user, account) do
    subject = Fixtures.subject_for(user, account, role: :owner)
    client = register_client!()
    {verifier, challenge} = pkce()

    {:ok, code} =
      OAuth.issue_code(
        client,
        %{
          "redirect_uri" => @redirect,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => "mcp offline_access",
          "resource" => @resource
        },
        subject
      )

    {:ok, tokens} =
      OAuth.exchange_code(%{
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => @redirect,
        "code_verifier" => verifier
      })

    tokens.access_token
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  describe "discovery metadata" do
    test "protected-resource points at the MCP endpoint + AS", %{conn: conn} do
      body =
        conn
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["resource"] =~ "/api/mcp/rpc"
      assert is_list(body["authorization_servers"])
      assert "mcp" in body["scopes_supported"]
      assert body["bearer_methods_supported"] == ["header"]
    end

    test "authorization-server advertises code + PKCE S256 + DCR", %{conn: conn} do
      body =
        conn
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert body["authorization_endpoint"] =~ "/oauth/authorize"
      assert body["token_endpoint"] =~ "/oauth/token"
      assert body["registration_endpoint"] =~ "/oauth/register"
      assert body["response_types_supported"] == ["code"]
      assert "refresh_token" in body["grant_types_supported"]
      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
    end
  end

  describe "POST /oauth/register" do
    test "registers a client and returns its id", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{
          "client_name" => "ChatGPT",
          "redirect_uris" => [@redirect]
        })
        |> json_response(201)

      assert is_binary(body["client_id"])
      assert body["token_endpoint_auth_method"] == "none"
      assert @redirect in body["redirect_uris"]
    end

    test "rejects an invalid redirect uri", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{"redirect_uris" => ["http://evil.example/cb"]})
        |> json_response(400)

      assert body["error"] == "invalid_client_metadata"
    end
  end

  describe "GET /oauth/authorize (consent)" do
    test "renders the consent screen for a logged-in operator", %{conn: conn, user: user} do
      client = register_client!("Claude Web")
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256",
        scope: "mcp offline_access",
        state: "xyz"
      }

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")
        |> html_response(200)

      assert html =~ "Authorize"
      assert html =~ "Claude Web"
      # PKCE challenge is carried through as a hidden field.
      assert html =~ challenge

      # Both known scopes render as human-readable grants, not raw tokens.
      assert html =~ "Run approved actions"
      assert html =~ "Stay connected"
    end

    test "scope_label falls back to the raw token for unknown scopes" do
      # Unreachable through the controller (scopes/1 filters to supported),
      # but the template-level fallback must never crash the consent page.
      assert EmisarWeb.OAuthHTML.scope_label("weird:scope") == "weird:scope"
    end

    test "shows an error page for an unknown client (no redirect)", %{conn: conn, user: user} do
      params = %{
        client_id: Ecto.UUID.generate(),
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: "abc",
        code_challenge_method: "S256"
      }

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")
        |> html_response(400)

      assert html =~ "Authorization error"
    end

    test "redirects unauthenticated operators to sign in", %{conn: conn} do
      client = register_client!()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: "abc",
        code_challenge_method: "S256"
      }

      conn = get(conn, ~p"/oauth/authorize?#{params}")
      assert redirected_to(conn) == ~p"/sign_in"
    end
  end

  describe "POST /oauth/authorize (decision)" do
    test "approve redirects back to the client with a code", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize", %{
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "response_type" => "code",
          "scope" => "mcp offline_access",
          "state" => "xyz",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "decision" => "approve"
        })

      location = redirected_to(conn, 302)
      assert location =~ "claude.ai"
      assert location =~ "code="
      assert location =~ "state=xyz"
    end

    test "deny redirects back with access_denied", %{conn: conn, user: user} do
      client = register_client!()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize", %{
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "state" => "xyz",
          "decision" => "deny"
        })

      location = redirected_to(conn, 302)
      assert location =~ "error=access_denied"
      assert location =~ "state=xyz"
    end
  end

  describe "POST /oauth/token" do
    test "exchanges an authorization code for tokens", %{conn: conn, user: user, account: account} do
      subject = Fixtures.subject_for(user, account, role: :owner)
      client = register_client!()
      {verifier, challenge} = pkce()

      {:ok, code} =
        OAuth.issue_code(
          client,
          %{
            "redirect_uri" => @redirect,
            "code_challenge" => challenge,
            "code_challenge_method" => "S256",
            "scope" => "mcp offline_access",
            "resource" => @resource
          },
          subject
        )

      body =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(200)

      assert "emo-" <> _ = body["access_token"]
      assert "emor-" <> _ = body["refresh_token"]
      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == 3600
    end

    test "rejects a bogus code with invalid_grant", %{conn: conn} do
      client = register_client!()

      body =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => "emoc-nope",
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => "whatever"
        })
        |> json_response(400)

      assert body["error"] == "invalid_grant"
    end

    test "rejects an unsupported grant type", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/token", %{"grant_type" => "client_credentials"})
        |> json_response(400)

      assert body["error"] == "unsupported_grant_type"
    end
  end

  describe "MCP endpoint accepts OAuth tokens" do
    defp rpc(conn, method) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/mcp/rpc", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method}))
    end

    test "an emo- access token authenticates", %{conn: conn, user: user, account: account} do
      token = mint_access_token(user, account)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> rpc("initialize")
        |> json_response(200)

      assert body["result"]["serverInfo"]["name"] == "emisar"
    end

    test "a missing token returns 401 with a WWW-Authenticate challenge", %{conn: conn} do
      conn = rpc(conn, "initialize")

      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Bearer"
      assert challenge =~ "resource_metadata="
      assert challenge =~ "/.well-known/oauth-protected-resource"
    end
  end
end
