defmodule EmisarWeb.OAuthControllerTest do
  @moduledoc """
  HTTP surface of the OAuth 2.1 authorization server: discovery
  metadata, Dynamic Client Registration, the consent screen, the token
  endpoint, and the resulting `emo-` access token working against the
  MCP JSON-RPC endpoint (with RFC 9728 `WWW-Authenticate` on 401).
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Crypto, Fixtures, OAuth, Repo}

  @redirect "https://claude.ai/api/mcp/auth_callback"
  @resource "https://emisar.dev/api/mcp/rpc"

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

  # Issue a code through the context with arbitrary params (lets a test set a
  # non-S256 method, or a verifier==challenge "plain" pairing the HTTP token
  # path must still refuse).
  defp issue_code!(user, account, params) do
    subject = Fixtures.subject_for(user, account, role: :owner)
    client = register_client!()

    {:ok, code} =
      OAuth.issue_code(
        client,
        Map.merge(
          %{
            "redirect_uri" => @redirect,
            "code_challenge_method" => "S256",
            "scope" => "mcp offline_access",
            "resource" => @resource
          },
          params
        ),
        subject
      )

    {client, code}
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

    # closes OAUTH-001-T03 — scopes_supported is EXACTLY OAuth.supported_scopes/0
    # (the two real scopes), with no extra/aspirational scopes leaking in.
    test "protected-resource scopes_supported is exactly the real set", %{conn: conn} do
      body =
        conn
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["scopes_supported"] == ["mcp", "offline_access"]
      assert body["scopes_supported"] == OAuth.supported_scopes()
    end

    # closes OAUTH-002-T03/OAUTH-002-T06 — the AS metadata advertises only what is
    # actually enforced: S256-only PKCE and code-only response type (matching the
    # consent + token enforcement), and "none" client auth (no client secret). The
    # dead `oauth_clients.client_secret_hash` column is never reflected as a
    # secret-bearing auth method.
    test "AS metadata advertises S256/code-only consistent with enforcement", %{conn: conn} do
      body =
        conn
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["response_types_supported"] == ["code"]
      assert body["scopes_supported"] == OAuth.supported_scopes()
      # Public PKCE clients only: no client-secret auth advertised, so the dead
      # client_secret_hash column is never surfaced.
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
      refute Enum.any?(body["token_endpoint_auth_methods_supported"], &(&1 =~ "secret"))
    end

    # closes OAUTH-001-T04/OAUTH-002-T04 — both discovery documents are
    # derived-config: junk query params on the GET are unconsumed and the body is
    # byte-for-byte identical to the clean request.
    test "junk query params on either discovery GET are ignored", %{conn: conn} do
      for path <- [
            "/.well-known/oauth-protected-resource",
            "/.well-known/oauth-authorization-server"
          ] do
        clean = conn |> get(path) |> json_response(200)

        junked =
          conn |> get(path <> "?evil=1&client_id=../../etc/passwd&x[]=y") |> json_response(200)

        assert junked == clean
      end
    end

    # closes OAUTH-001-T06/OAUTH-002-T07 — both discovery documents ride the
    # CSRF-free `:api` pipeline (no `:protect_from_forgery`), so a cross-origin
    # GET with no CSRF token succeeds. Read-only discovery is CSRF-inapplicable;
    # this pins that it's served without a session/forgery token. We clear
    # `plug_skip_csrf_protection` (ConnTest sets it by default) so the real
    # pipeline runs — a GET on `:api` has no CSRF plug to trip either way.
    test "the discovery GETs need no CSRF token (served on :api)", %{conn: conn} do
      for path <- [
            "/.well-known/oauth-protected-resource",
            "/.well-known/oauth-authorization-server"
          ] do
        assert conn
               |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
               |> get(path)
               |> json_response(200)
      end
    end

    # closes OAUTH-001-T07 — every URL in both documents derives from the
    # configured `Endpoint.url()`, NOT an attacker-supplied Host header: sending a
    # forged Host doesn't shift `resource`/`authorization_servers`/the endpoint
    # URLs to that host (no host-header injection of the advertised trust).
    test "the advertised URLs derive from the configured base, not the Host header", %{conn: conn} do
      base = EmisarWeb.Endpoint.url()

      forged = fn path ->
        %{conn | host: "attacker.example"}
        |> get(path)
        |> json_response(200)
      end

      pr = forged.("/.well-known/oauth-protected-resource")
      assert pr["resource"] == base <> "/api/mcp/rpc"
      assert pr["authorization_servers"] == [base]
      refute pr["resource"] =~ "attacker.example"

      as = forged.("/.well-known/oauth-authorization-server")
      assert as["issuer"] == base
      assert as["authorization_endpoint"] == base <> "/oauth/authorize"
      assert as["token_endpoint"] == base <> "/oauth/token"
      refute as["registration_endpoint"] =~ "attacker.example"
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

    # closes OAUTH-003-T03 — `redirect_uris` may arrive as a single bare string;
    # list_param/3 normalizes it to a one-element list and registration succeeds.
    test "redirect_uris accepts a single string (normalized to a list)", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{
          "client_name" => "Single",
          "redirect_uris" => @redirect
        })
        |> json_response(201)

      assert body["redirect_uris"] == [@redirect]
    end

    # closes OAUTH-003-T06 — multiple valid https redirect_uris are all stored, so
    # each is later usable for the authorize exact-match.
    test "registers multiple redirect_uris", %{conn: conn} do
      second = "https://chatgpt.com/connector_platform_oauth_redirect"

      body =
        conn
        |> post_json(~p"/oauth/register", %{
          "client_name" => "Multi",
          "redirect_uris" => [@redirect, second]
        })
        |> json_response(201)

      assert @redirect in body["redirect_uris"]
      assert second in body["redirect_uris"]
      assert length(body["redirect_uris"]) == 2
    end

    # closes OAUTH-003-T04 — a client_name at the 200-char max is accepted
    # (validate_length max: 200, inclusive).
    test "client_name at the 200-char max is accepted", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{
          "client_name" => String.duplicate("a", 200),
          "redirect_uris" => [@redirect]
        })
        |> json_response(201)

      assert String.length(body["client_name"]) == 200
    end

    # closes OAUTH-003-T05 — one char over the 200 max is rejected as
    # invalid_client_metadata (length error).
    test "client_name over 200 chars is rejected", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{
          "client_name" => String.duplicate("a", 201),
          "redirect_uris" => [@redirect]
        })
        |> json_response(400)

      assert body["error"] == "invalid_client_metadata"
    end

    # closes OAUTH-003-T08 — a non-list, non-string `redirect_uris` (here a number)
    # falls to list_param's default [], so the at-least-one rule rejects it.
    test "a non-list, non-string redirect_uris is rejected", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{"client_name" => "Bad", "redirect_uris" => 42})
        |> json_response(400)

      assert body["error"] == "invalid_client_metadata"
    end

    # closes OAUTH-003-T09 — a malformed metadata mix returns the flattened
    # changeset errors in `error_description` (the redirect_uris field error text
    # surfaces verbatim), not a bare error code.
    test "malformed metadata flattens the changeset errors into error_description", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{"client_name" => "NoRedirect"})
        |> json_response(400)

      assert body["error"] == "invalid_client_metadata"
      assert is_binary(body["error_description"])
      assert body["error_description"] =~ "redirect_uris"
      assert body["error_description"] =~ "at least one redirect_uri is required"
    end

    # closes OAUTH-003-T12 — the full loopback allow-list (127.0.0.1 and [::1])
    # gets the http exception, same as localhost.
    test "http loopback hosts 127.0.0.1 and [::1] are accepted", %{conn: conn} do
      for uri <- ["http://127.0.0.1/cb", "http://[::1]/cb"] do
        body =
          conn
          |> post_json(~p"/oauth/register", %{
            "client_name" => "Loopback",
            "redirect_uris" => [uri]
          })
          |> json_response(201)

        assert uri in body["redirect_uris"]
      end
    end

    # closes OAUTH-003-T13 — only EXACT loopback hosts get the http exception; a
    # look-alike like localhost.evil.com is plain http and rejected.
    test "an http non-loopback look-alike host is rejected", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{
          "client_name" => "Evil",
          "redirect_uris" => ["http://localhost.evil.com/cb"]
        })
        |> json_response(400)

      assert body["error"] == "invalid_client_metadata"
    end

    # closes OAUTH-003-T14 — DCR is a machine endpoint on the CSRF-free `:api`
    # pipeline: a cross-origin POST with no session and no CSRF token still
    # registers (201). The request itself mints the client — there is no
    # `%Subject{}`, so a forgery token would be meaningless. We clear
    # `plug_skip_csrf_protection` to run the real pipeline; `:api` carries no
    # `:protect_from_forgery`, so the tokenless POST is accepted (NOT a vuln —
    # correct for a public client-registration API).
    test "DCR accepts a tokenless cross-origin POST (CSRF-free :api)", %{conn: conn} do
      body =
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post_json(~p"/oauth/register", %{
          "client_name" => "No CSRF Token",
          "redirect_uris" => [@redirect]
        })
        |> json_response(201)

      assert is_binary(body["client_id"])
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

    # closes OAUTH-004-T02 — every authorize param the POST needs is echoed back as
    # a hidden field, so the form carries the same PKCE challenge/method/state/
    # resource the GET validated.
    test "all authorize params are echoed as hidden fields", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256",
        scope: "mcp offline_access",
        state: "the-state-value",
        resource: @resource
      }

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")
        |> html_response(200)

      for {name, value} <- [
            {"client_id", client.id},
            {"redirect_uri", @redirect},
            {"response_type", "code"},
            {"scope", "mcp offline_access"},
            {"state", "the-state-value"},
            {"code_challenge", challenge},
            {"code_challenge_method", "S256"},
            {"resource", @resource}
          ] do
        assert html =~ ~s(type="hidden")
        assert html =~ ~s(name="#{name}")
        assert html =~ value
      end
    end

    # closes OAUTH-004-T04 — an empty scope string narrows the displayed grant
    # list to ["mcp"] (scopes/1: an all-unsupported/empty request keeps the base
    # "mcp" capability), so the consent page still shows a concrete grant rather
    # than blank. (An *absent* scope is the nil clause, which keeps both defaults
    # — that's the main render test's path.)
    test "an empty scope string narrows the shown grant to mcp", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256",
        scope: ""
      }

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")
        |> html_response(200)

      # The "mcp" scope label renders; the offline_access one does not.
      assert html =~ "Run approved actions"
      refute html =~ "Stay connected"
    end

    # closes OAUTH-004-T16 — the consent screen carries a noindex assign (the
    # controller's put_noindex + the :noindex pipeline), keeping the auth surface
    # out of search-engine indexes.
    test "the consent screen is noindex", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256"
      }

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")

      assert conn.assigns[:noindex] == true
      assert html_response(conn, 200) =~ "noindex"
    end

    # closes OAUTH-004-T03 — the consent screen renders the three trust
    # assurances, so the operator sees the guardrails (policy-permitted only,
    # attributed + recorded, approval still waits) before granting.
    test "the consent screen renders the trust assurances", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256"
      }

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")
        |> html_response(200)

      assert html =~ "only run actions your policy already permits"
      assert html =~ "attributed to you and recorded in the audit log"
      assert html =~ "requiring approval still waits for a human"
    end

    # closes OAUTH-004-T13 — code_challenge_method may be omitted; it defaults to
    # S256 (the validate_request nil clause), so the consent still renders rather
    # than redirecting back with invalid_request.
    test "an absent code_challenge_method defaults to S256 and renders consent", %{
      conn: conn,
      user: user
    } do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        scope: "mcp offline_access",
        state: "xyz"
      }

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")
        |> html_response(200)

      assert html =~ "Authorize"
      # The hidden method field is filled in as S256 for the POST.
      assert html =~ ~s(name="code_challenge_method")
      assert html =~ "S256"
    end

    # closes OAUTH-004-T15 — the consent GET is render-only: it mints no
    # authorization code, no token, and writes no audit event (nothing happens
    # until the operator POSTs a decision).
    test "the consent GET mints nothing and writes no audit", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256",
        scope: "mcp offline_access"
      }

      codes_before = Repo.aggregate(OAuth.AuthorizationCode, :count)
      tokens_before = Repo.aggregate(OAuth.Token, :count)
      audit_before = Repo.aggregate(Emisar.Audit.Event, :count)

      conn
      |> log_in_user(user)
      |> get(~p"/oauth/authorize?#{params}")
      |> html_response(200)

      assert Repo.aggregate(OAuth.AuthorizationCode, :count) == codes_before
      assert Repo.aggregate(OAuth.Token, :count) == tokens_before
      assert Repo.aggregate(Emisar.Audit.Event, :count) == audit_before
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

    # closes OAUTH-004-T10 — a bad response_type is an OAuth error the client
    # CAN be told about (client + redirect already validated), so it redirects
    # back with error=unsupported_response_type rather than showing an error page.
    test "bad response_type redirects back with unsupported_response_type", %{
      conn: conn,
      user: user
    } do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "token",
        code_challenge: challenge,
        code_challenge_method: "S256",
        state: "xyz"
      }

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")

      location = redirected_to(conn, 302)
      assert location =~ "claude.ai"
      assert location =~ "error=unsupported_response_type"
      assert location =~ "state=xyz"
    end

    # closes OAUTH-004-T11 — PKCE is mandatory: a missing or empty code_challenge
    # is invalid_request, redirected back to the (validated) client.
    test "missing or empty code_challenge redirects back with invalid_request", %{
      conn: conn,
      user: user
    } do
      client = register_client!()

      missing = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge_method: "S256",
        state: "xyz"
      }

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{missing}")

      assert redirected_to(conn, 302) =~ "error=invalid_request"

      empty = Map.put(missing, :code_challenge, "")

      conn =
        build_conn()
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{empty}")

      assert redirected_to(conn, 302) =~ "error=invalid_request"
    end

    # closes OAUTH-004-T12 — MCP mandates S256; code_challenge_method=plain is
    # rejected at the consent GET (redirected back as invalid_request).
    test "code_challenge_method=plain is rejected (S256 only)", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "plain",
        state: "xyz"
      }

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")

      location = redirected_to(conn, 302)
      assert location =~ "error=invalid_request"
      assert location =~ "state=xyz"
    end

    # closes OAUTH-004-T07 — a non-UUID client_id can't be cast to a binary_id;
    # fetch_client guards it to a clean not-found → error page, NOT a redirect
    # (OAuth 2.1: we can't trust where an unknown client would land).
    test "a malformed (non-UUID) client_id shows an error page, not a redirect", %{
      conn: conn,
      user: user
    } do
      params = %{
        client_id: "not-a-uuid",
        redirect_uri: @redirect,
        response_type: "code",
        code_challenge: "abc",
        code_challenge_method: "S256"
      }

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")

      assert html_response(conn, 400) =~ "Authorization error"
      # An error page, not a 302 — there is no Location header to an unvetted origin.
      assert get_resp_header(conn, "location") == []
    end

    # closes OAUTH-004-T08 — a redirect_uri the client never registered must NOT
    # bounce to that unvetted origin; error page instead.
    test "an unregistered redirect_uri shows an error page, not a redirect", %{
      conn: conn,
      user: user
    } do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        redirect_uri: "https://attacker.example/cb",
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256"
      }

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")

      assert html_response(conn, 400) =~ "Authorization error"
      # An error page, not a 302 — there is no Location header to an unvetted origin.
      assert get_resp_header(conn, "location") == []
    end

    # closes OAUTH-004-T09 — an absent redirect_uri hits check_redirect's
    # non-binary clause → :error → error page (never a redirect to nowhere).
    test "a missing redirect_uri shows an error page", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      params = %{
        client_id: client.id,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256"
      }

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")

      assert html_response(conn, 400) =~ "Authorization error"
      # An error page, not a 302 — there is no Location header to an unvetted origin.
      assert get_resp_header(conn, "location") == []
    end
  end

  describe "POST /oauth/authorize (decision)" do
    # closes OAUTH-005-T15 — `state` is echoed on the approve redirect-back (the
    # deny case asserts the same below).
    # closes OAUTH-005-T17 — the consenting operator is an OWNER (has key-issue)
    # approving for their OWN membership; self-approval is permitted (consistent
    # with the product's self-approval stance) and the code is issued.
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

    # closes OAUTH-005-T11 — anything that isn't exactly "approve" is treated as a
    # denial: an unexpected decision=maybe redirects back with access_denied (and
    # the state is preserved), mints nothing.
    test "a non-approve decision is treated as access_denied", %{conn: conn, user: user} do
      client = register_client!()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize", %{
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "state" => "xyz",
          "decision" => "maybe"
        })

      location = redirected_to(conn, 302)
      assert location =~ "error=access_denied"
      assert location =~ "state=xyz"
      refute location =~ "code="
    end

    # closes OAUTH-005-T13 — an empty scope on approve is narrowed server-side to
    # the default "mcp offline_access" (narrow_scope/1), so the persisted code's
    # scope is the default, never blank.
    test "approve with an empty scope narrows to the default", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize", %{
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "response_type" => "code",
          "scope" => "",
          "state" => "xyz",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "decision" => "approve"
        })

      location = redirected_to(conn, 302)

      raw_code =
        location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("code")

      row = Repo.get_by!(OAuth.AuthorizationCode, code_hash: Crypto.hash(raw_code))
      assert row.scope == "mcp offline_access"
    end

    # closes OAUTH-005-T07 — the POST re-runs the same client/redirect gate as
    # the GET: an unknown client_id is an error page, never a redirect.
    test "an unknown client at POST shows an error page", %{conn: conn, user: user} do
      {_verifier, challenge} = pkce()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize", %{
          "client_id" => Ecto.UUID.generate(),
          "redirect_uri" => @redirect,
          "response_type" => "code",
          "scope" => "mcp offline_access",
          "state" => "xyz",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "decision" => "approve"
        })

      assert html_response(conn, 400) =~ "Authorization error"
      assert get_resp_header(conn, "location") == []
    end

    # closes OAUTH-005-T14 — the consent POST rides the :browser pipeline, so
    # :protect_from_forgery rejects a same-origin form POST with no CSRF token.
    # Phoenix.ConnTest skips CSRF by default (`plug_skip_csrf_protection`), so we
    # clear that flag to exercise the real pipeline: with no `_csrf_token` the
    # plug raises InvalidCSRFTokenError (plug_status 403).
    test "the consent POST is CSRF-protected", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      assert_error_sent(403, fn ->
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
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
      end)
    end

    # closes OAUTH-005-T16 — the raw emoc- code is delivered ONLY via the
    # redirect; the oauth_authz_codes row stores the sha256 code_hash, never
    # the clear code.
    test "the code is delivered via redirect and stored hashed at rest", %{conn: conn, user: user} do
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

      raw_code =
        location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("code")

      assert "emoc-" <> _ = raw_code

      # The row is keyed by the sha256 of the raw code; the clear code is
      # nowhere in the table.
      row = Repo.get_by!(OAuth.AuthorizationCode, code_hash: Crypto.hash(raw_code))
      assert is_binary(row.code_hash)
      refute Repo.get_by(OAuth.AuthorizationCode, code_hash: raw_code)
    end

    # closes OAUTH-005-T06 — the minted authorization code is short-lived: its
    # stored expires_at is ~60s out (@code_ttl_s), so a leaked code is only
    # briefly exchangeable.
    test "the approved code carries a 60s TTL", %{conn: conn, user: user} do
      client = register_client!()
      {_verifier, challenge} = pkce()

      before = DateTime.utc_now()

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

      raw_code =
        conn
        |> redirected_to(302)
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("code")

      row = Repo.get_by!(OAuth.AuthorizationCode, code_hash: Crypto.hash(raw_code))
      assert_in_delta DateTime.diff(row.expires_at, before, :second), 60, 5
    end

    # closes OAUTH-005-T08 — the POST runs the same redirect gate as the GET: an
    # unregistered redirect_uri is an error page, never a bounce to the unvetted
    # origin (even on approve).
    test "an unregistered redirect_uri at POST shows an error page, not a redirect", %{
      conn: conn,
      user: user
    } do
      client = register_client!()
      {_verifier, challenge} = pkce()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize", %{
          "client_id" => client.id,
          "redirect_uri" => "https://attacker.example/cb",
          "response_type" => "code",
          "scope" => "mcp offline_access",
          "state" => "xyz",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "decision" => "approve"
        })

      assert html_response(conn, 400) =~ "Authorization error"
      assert get_resp_header(conn, "location") == []
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

    # closes OAUTH-006-T11 — `plain` is never honored. Here the stored code is
    # marked method=plain with the challenge == verifier (so it WOULD pass under
    # plain); the S256-only pkce_ok?/2 still rejects it as invalid_grant.
    test "code_challenge_method=plain is not honored (S256 only)", %{
      conn: conn,
      user: user,
      account: account
    } do
      # 43-char verifier so the RFC 7636 length guard passes — the failure must
      # come from the S256-only check, not the length pre-filter.
      verifier = "plain_method_verifier_aaaaaaaaaaaaaaaaaaaaaa"
      assert byte_size(verifier) in 43..128

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => verifier,
          "code_challenge_method" => "plain"
        })

      body =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(400)

      assert body["error"] == "invalid_grant"
    end

    # closes OAUTH-006-T05 — a code aged past its 60s TTL is invalid_grant
    # (check_code_live → live?/1 false). Backdate expires_at instead of sleeping.
    test "an expired code is rejected with invalid_grant", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      past = DateTime.add(DateTime.utc_now(), -120, :second)

      {1, _} =
        OAuth.AuthorizationCode.Query.all()
        |> OAuth.AuthorizationCode.Query.by_code_hash(Crypto.hash(code))
        |> Repo.update_all(set: [expires_at: past])

      body =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(400)

      assert body["error"] == "invalid_grant"
    end

    # closes OAUTH-006-T04 — the minted token carries the real TTLs: access
    # expires_at ≈ now+1h and refresh expires_at ≈ now+30d (asserted on the stored
    # row, not just the response's expires_in).
    test "the issued token row carries the 1h access + 30d refresh TTLs", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      before = DateTime.utc_now()

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

      assert body["expires_in"] == 3600

      token = Repo.get_by!(OAuth.Token, access_token_hash: Crypto.hash(body["access_token"]))

      access_ttl = DateTime.diff(token.access_expires_at, before, :second)
      refresh_ttl = DateTime.diff(token.refresh_expires_at, before, :second)

      assert_in_delta access_ttl, 3_600, 30
      assert_in_delta refresh_ttl, 30 * 24 * 3_600, 30
    end

    # closes OAUTH-007-T06 — a refresh_token grant with a random/bogus refresh
    # token resolves no row and is rejected as invalid_grant.
    test "an unknown refresh token is rejected with invalid_grant", %{conn: conn} do
      client = register_client!()

      body =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => "emor-not-a-real-token",
          "client_id" => client.id
        })
        |> json_response(400)

      assert body["error"] == "invalid_grant"
    end

    # closes OAUTH-007-T10 — a refresh token aged past its 30d TTL is rejected as
    # invalid_grant (live?(refresh_expires_at) false). Backdate the stored expiry
    # rather than waiting 30 days.
    test "an expired refresh token is rejected with invalid_grant", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      issued =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(200)

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, _} =
        OAuth.Token.Query.all()
        |> OAuth.Token.Query.by_refresh_hash(Crypto.hash(issued["refresh_token"]))
        |> Repo.update_all(set: [refresh_expires_at: past])

      body =
        build_conn()
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => issued["refresh_token"],
          "client_id" => client.id
        })
        |> json_response(400)

      assert body["error"] == "invalid_grant"
    end

    # closes OAUTH-007-T01 — the refresh_token grant over HTTP rotates the pair:
    # a fresh emo-/emor- both differ from the old, and the old refresh dies.
    test "refresh_token grant rotates the pair over HTTP", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      first =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(200)

      rotated =
        build_conn()
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first["refresh_token"],
          "client_id" => client.id
        })
        |> json_response(200)

      assert "emo-" <> _ = rotated["access_token"]
      assert "emor-" <> _ = rotated["refresh_token"]
      assert rotated["access_token"] != first["access_token"]
      assert rotated["refresh_token"] != first["refresh_token"]

      # The old refresh token is now dead (single-use rotation).
      reused =
        build_conn()
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first["refresh_token"],
          "client_id" => client.id
        })
        |> json_response(400)

      assert reused["error"] == "invalid_grant"
    end

    # closes OAUTH-006-T13 — the RFC 7636 verifier guard rejects an over-long
    # (>128-char) verifier and one with an illegal character BEFORE hashing, so
    # both are invalid_grant. The challenge matches each verifier, so the failure
    # is the length/charset pre-filter, not a PKCE mismatch.
    test "an over-long or bad-charset PKCE verifier is rejected with invalid_grant", %{
      conn: conn,
      user: user,
      account: account
    } do
      too_long = String.duplicate("a", 129)
      bad_charset = "bad+charset/verifier=with*illegal(chars)aaaaaaa"
      assert byte_size(bad_charset) in 43..128

      for verifier <- [too_long, bad_charset] do
        challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

        {client, code} =
          issue_code!(user, account, %{
            "code_challenge" => challenge,
            "code_challenge_method" => "S256"
          })

        body =
          conn
          |> post_json(~p"/oauth/token", %{
            "grant_type" => "authorization_code",
            "code" => code,
            "client_id" => client.id,
            "redirect_uri" => @redirect,
            "code_verifier" => verifier
          })
          |> json_response(400)

        assert body["error"] == "invalid_grant", "expected invalid_grant for #{inspect(verifier)}"
      end
    end

    # closes OAUTH-006-T18 — the RFC 8707 `resource` is accepted and persisted on
    # the issued token row, but it is NOT enforced as an audience binding yet
    # (single protected resource today). Asserts the current behavior end-to-end.
    test "the resource is carried onto the token row but not enforced", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()
      # issue_code! sets "resource" => @resource on the code.
      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

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

      token = Repo.get_by!(OAuth.Token, access_token_hash: Crypto.hash(body["access_token"]))
      assert token.resource == @resource
    end

    # closes OAUTH-006-T20 — the client is public (auth method "none"): a
    # client_secret sent alongside the exchange is simply ignored — auth is
    # code + verifier only. The exchange still succeeds.
    test "a client_secret on the exchange is ignored (public client)", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      body =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier,
          "client_secret" => "ignored-secret"
        })
        |> json_response(200)

      assert "emo-" <> _ = body["access_token"]
    end

    # closes OAUTH-007-T02 — the rotated pair carries the SAME backing key, account,
    # and scope as the prior token (no re-consent): resolving the new access token
    # yields the original account + the backing key's scopes.
    test "the refreshed pair carries forward the backing key + scope (HTTP)", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      first =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(200)

      {:ok, %{api_key: original_key}} = OAuth.resolve_access_token(first["access_token"])

      rotated =
        build_conn()
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first["refresh_token"],
          "client_id" => client.id
        })
        |> json_response(200)

      assert {:ok, %{api_key: rotated_key, account: acct}} =
               OAuth.resolve_access_token(rotated["access_token"])

      # Same backing key + account — the grant carried forward, no re-consent.
      assert rotated_key.id == original_key.id
      assert acct.id == account.id
      assert rotated["scope"] == first["scope"]
    end

    # closes OAUTH-007-T03 — the rotated token row resets its TTLs: a fresh 1h
    # access window + a fresh 30d refresh window (asserted on the stored row).
    test "the rotated token row resets its 1h access + 30d refresh TTLs", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      first =
        conn
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(200)

      before = DateTime.utc_now()

      rotated =
        build_conn()
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first["refresh_token"],
          "client_id" => client.id
        })
        |> json_response(200)

      assert rotated["expires_in"] == 3600

      row = Repo.get_by!(OAuth.Token, access_token_hash: Crypto.hash(rotated["access_token"]))
      assert_in_delta DateTime.diff(row.access_expires_at, before, :second), 3_600, 30
      assert_in_delta DateTime.diff(row.refresh_expires_at, before, :second), 30 * 24 * 3_600, 30
    end

    # closes OAUTH-006-T22/OAUTH-007-T12 — the token endpoint rides the CSRF-free
    # `:api` pipeline (router): both the authorization_code exchange and the
    # refresh rotation succeed on a cross-origin POST with no CSRF token. The
    # credential IS the code+verifier (resp. the refresh token), not a browser
    # forgery token — so a tokenless POST must work (correct for a public-client
    # machine API). We clear `plug_skip_csrf_protection` to run the real pipeline.
    test "the token endpoint accepts a tokenless POST for both grants (CSRF-free :api)", %{
      conn: conn,
      user: user,
      account: account
    } do
      {verifier, challenge} = pkce()

      {client, code} =
        issue_code!(user, account, %{
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        })

      issued =
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })
        |> json_response(200)

      assert "emo-" <> _ = issued["access_token"]

      # The refresh grant is the same CSRF-free machine call.
      rotated =
        build_conn()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post_json(~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => issued["refresh_token"],
          "client_id" => client.id
        })
        |> json_response(200)

      assert "emo-" <> _ = rotated["access_token"]
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
