defmodule Emisar.OAuthTest do
  @moduledoc """
  The OAuth 2.1 authorization server: DCR, authorization-code + PKCE,
  refresh-token rotation, and access-token resolution to the backing
  API key. These are the paths the Claude.ai / ChatGPT connectors drive.
  """
  use Emisar.DataCase, async: true
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Fixtures
  alias Emisar.OAuth
  alias Emisar.OAuth.{AuthorizationCode, Client, Token}

  @redirect "https://claude.ai/api/mcp/auth_callback"
  @resource Emisar.PublicUrl.url("/api/mcp/rpc")

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  defp register!(name \\ "Claude") do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => name, "redirect_uris" => [@redirect]})

    client
  end

  defp backdate_registration(%Client{id: id}, days) do
    ts = DateTime.add(DateTime.utc_now(), days * 86_400, :second)
    {1, _} = Client.Query.by_id(id) |> Repo.update_all(set: [inserted_at: ts])
  end

  defp issue!(subject, client, challenge, opts \\ []) do
    {:ok, code} =
      OAuth.issue_code(
        client,
        %{
          "redirect_uri" => @redirect,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => opts[:scope] || "mcp offline_access",
          "resource" => @resource
        },
        subject
      )

    code
  end

  describe "register_client/1" do
    test "registers a PKCE public client" do
      assert {:ok, %Client{} = client} =
               OAuth.register_client(%{
                 "client_name" => "ChatGPT",
                 "redirect_uris" => [@redirect]
               })

      assert client.client_name == "ChatGPT"
      assert @redirect in client.redirect_uris
    end

    test "rejects confidential-client auth methods" do
      assert {:error, changeset} =
               OAuth.register_client(%{
                 "client_name" => "Secret Client",
                 "redirect_uris" => [@redirect],
                 "token_endpoint_auth_method" => "client_secret_post"
               })

      assert "must be none" in errors_on(changeset).token_endpoint_auth_method
    end

    test "rejects a non-https / non-localhost redirect uri" do
      assert {:error, changeset} =
               OAuth.register_client(%{"redirect_uris" => ["http://evil.example/cb"]})

      refute changeset.valid?
    end

    test "requires at least one redirect uri" do
      assert {:error, _changeset} = OAuth.register_client(%{"client_name" => "X"})
    end

    test "accepts an http://localhost loopback redirect (native/dev clients)" do
      assert {:ok, %Client{} = client} =
               OAuth.register_client(%{
                 "client_name" => "Native App",
                 "redirect_uris" => ["http://localhost:8723/callback"]
               })

      assert "http://localhost:8723/callback" in client.redirect_uris
    end

    test "rejects an unsupported grant type (only authorization_code + refresh_token)" do
      assert {:error, changeset} =
               OAuth.register_client(%{
                 "client_name" => "Implicit",
                 "redirect_uris" => [@redirect],
                 "grant_types" => ["authorization_code", "implicit"]
               })

      assert "unsupported grant_type" in errors_on(changeset).grant_types
    end

    test "rejects an unsupported response type (only code)" do
      assert {:error, changeset} =
               OAuth.register_client(%{
                 "client_name" => "Token",
                 "redirect_uris" => [@redirect],
                 "response_types" => ["token"]
               })

      assert "unsupported response_type" in errors_on(changeset).response_types
    end
  end

  describe "fetch_client/1" do
    test "loads a registered client by its client_id" do
      client = register!("Resolvable")

      assert {:ok, %Client{id: id, client_name: "Resolvable"}} = OAuth.fetch_client(client.id)
      assert id == client.id
    end

    test "an unknown but well-formed uuid is :not_found" do
      assert {:error, :not_found} = OAuth.fetch_client(Ecto.UUID.generate())
    end

    test "a malformed (non-uuid) client_id is a clean :not_found, never a 500" do
      # A connector can send any string as client_id; the binary_id cast is
      # guarded so a non-uuid is :not_found, not a cast crash.
      assert {:error, :not_found} = OAuth.fetch_client("not-a-uuid")
    end

    test "a non-binary client_id is a clean :not_found (the guard's fallback clause)" do
      assert {:error, :not_found} = OAuth.fetch_client(nil)
    end
  end

  describe "issue_code/3 authorization gate" do
    test "a read-only viewer cannot consent — the OAuth flow can't mint an execute token they couldn't issue manually" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      # A viewer has view_api_keys but not issue_quick_key, so they can't mint
      # an API key in-product — and must not be able to via consent either.
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert {:error, :unauthorized} =
               OAuth.issue_code(
                 client,
                 %{
                   "redirect_uri" => @redirect,
                   "code_challenge" => challenge,
                   "code_challenge_method" => "S256",
                   "scope" => "mcp offline_access",
                   "resource" => @resource
                 },
                 viewer
               )
    end

    test "a suspended membership cannot mint a backing key from a stale subject" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.suspend_membership(membership)
      client = register!()
      {_verifier, challenge} = pkce()

      assert {:error, :not_found} =
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

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
      assert Repo.reload!(client).last_authorized_at == nil
    end

    test "a removed membership cannot mint a backing key from a stale subject" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.mark_membership_as_deleted(membership)
      client = register!()
      {_verifier, challenge} = pkce()

      assert {:error, :not_found} =
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

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a fresh membership role must still have the key-issue permission" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "viewer")
      client = register!()
      {_verifier, challenge} = pkce()

      assert {:error, :unauthorized} =
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

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "an active membership still mints a backing key" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()

      assert {:ok, _code} =
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

      assert Repo.exists?(ApiKey.Query.all())
      assert Repo.exists?(AuthorizationCode.Query.all())
    end
  end

  describe "exchange_code/1" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject, client: register!()}
    end

    test "issue + exchange yields tokens bound to a backing key",
         %{subject: subject, client: client, account: account} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:ok, tokens} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      assert "emo-" <> _ = tokens.access_token
      assert "emor-" <> _ = tokens.refresh_token
      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == 3600

      assert {:ok, %{api_key: key, account: acct}} =
               OAuth.resolve_access_token(tokens.access_token, @resource)

      assert acct.id == account.id
      assert key.kind == :mcp
    end

    test "the backing key is minted NON-expiring so a long-lived OAuth connection never breaks on key expiry",
         %{subject: subject, client: client} do
      {_verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      code_row =
        Repo.get_by!(Emisar.OAuth.AuthorizationCode, code_hash: Emisar.Crypto.hash(code))

      key = Repo.get!(Emisar.ApiKeys.ApiKey, code_row.api_key_id)

      # OAuth owns the lifecycle (refresh-token expiry retires an abandoned
      # connection; revocation is the off-switch). The 30-day static-MCP-key
      # self-heal must NOT apply, or every OAuth connection would die 30 days
      # after consent even while it is actively refreshing.
      assert key.expires_at == nil
      assert Emisar.ApiKeys.ApiKey.usable?(key)
    end

    test "consent audits oauth.consent_granted with the backing key as subject",
         %{subject: subject, client: client} do
      {_verifier, challenge} = pkce()
      _code = issue!(subject, client, challenge)

      {:ok, [event], _meta} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["oauth.consent_granted"]])

      assert event.actor_id == Emisar.Auth.Subject.actor_id(subject)
      assert event.target_kind == "api_key"
      assert event.payload["client_id"] == client.id
    end

    test "fails closed (without burning the code) when the backing key was revoked before exchange",
         %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      # Revoke the consent-created backing key before exchange — the operator's
      # OAuth off-switch must stop a pre-revocation code from minting tokens.
      code_row =
        Repo.get_by!(Emisar.OAuth.AuthorizationCode, code_hash: Emisar.Crypto.hash(code))

      key = Repo.get!(Emisar.ApiKeys.ApiKey, code_row.api_key_id)
      Repo.update!(Ecto.Changeset.change(key, revoked_at: DateTime.utc_now()))

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      # The failed check rolled back the burn — the one-time code stays unused.
      assert Repo.get!(Emisar.OAuth.AuthorizationCode, code_row.id).used_at == nil
    end

    test "a disabled account cannot exchange a retained authorization code",
         %{account: account, subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      assert Repo.get_by!(Emisar.OAuth.AuthorizationCode, code_hash: Emisar.Crypto.hash(code)).used_at ==
               nil
    end

    test "rejects a tampered PKCE verifier", %{subject: subject, client: client} do
      {_verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => "definitely-the-wrong-verifier"
               })
    end

    test "rejects a too-short PKCE verifier (RFC 7636 §4.1)", %{subject: subject, client: client} do
      # A 20-char verifier whose challenge DOES match — without the length guard,
      # pkce_ok? would accept it; the guard rejects the entropy downgrade first.
      short = "abcdefghij0123456789"
      challenge = Base.url_encode64(:crypto.hash(:sha256, short), padding: false)
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => short
               })
    end

    test "the code is single-use", %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      params = %{
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => @redirect,
        "code_verifier" => verifier
      }

      assert {:ok, _} = OAuth.exchange_code(params)
      assert {:error, :invalid_grant} = OAuth.exchange_code(params)
    end

    test "rejects a mismatched redirect_uri", %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => "https://claude.ai/somewhere-else",
                 "code_verifier" => verifier
               })
    end

    test "rejects a code replayed by a different client",
         %{subject: subject, client: client} do
      other = register!("Other")
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => other.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })
    end

    test "omits the refresh token when offline_access is not requested",
         %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge, scope: "mcp")

      assert {:ok, tokens} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      assert tokens.refresh_token == nil
    end

    test "narrows the granted scope to supported values, dropping anything else",
         %{client: client, subject: subject} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge, scope: "mcp evil:custom offline_access")

      {:ok, tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      # `evil:custom` is client-controlled in the consent POST; only the
      # supported scopes persist on the grant.
      assert tokens.scope == "mcp offline_access"
    end

    test "an offline_access-only request still carries the mandatory mcp scope",
         %{client: client, subject: subject} do
      # A client asking for `offline_access` (a refresh token) without naming
      # `mcp` must still get `mcp` — that scope IS the MCP capability, so the
      # token would be useless (and rejected at the resource server) without it.
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge, scope: "offline_access")

      {:ok, tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      assert tokens.scope == "mcp offline_access"
      assert {:ok, _} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end

    test "rejects a token request whose resource mismatches the granted resource (RFC 8707)",
         %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_target} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier,
                 "resource" => "https://other.example/mcp"
               })
    end

    test "accepts a token request that repeats the matching resource",
         %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:ok, _tokens} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier,
                 "resource" => @resource
               })
    end

    test "a request missing the required params is :invalid_request, not a crash" do
      # The arity-1 fallback clause catches any param map lacking
      # code/client_id/redirect_uri/code_verifier — a malformed token POST.
      assert {:error, :invalid_request} = OAuth.exchange_code(%{})
    end
  end

  describe "refresh/1" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      {:ok, tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      %{account: account, client: client, tokens: tokens}
    end

    test "rotates the refresh token and issues a fresh access token",
         %{client: client, tokens: tokens} do
      assert {:ok, fresh} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id
               })

      assert "emo-" <> _ = fresh.access_token
      assert fresh.access_token != tokens.access_token
      assert "emor-" <> _ = fresh.refresh_token
      assert fresh.refresh_token != tokens.refresh_token

      # The rotated (old) refresh token is dead.
      assert {:error, :invalid_grant} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id
               })

      # The new access token resolves.
      assert {:ok, _} = OAuth.resolve_access_token(fresh.access_token, @resource)
    end

    test "fails closed once the backing api_key is revoked", %{client: client, tokens: tokens} do
      # Revoking the backing key is the operator's off-switch for an OAuth
      # connection — refresh must then stop minting access tokens, not keep
      # the 30-day grant alive over a dead key.
      {:ok, %{api_key: key}} = OAuth.resolve_access_token(tokens.access_token, @resource)

      key
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Emisar.Repo.update!()

      assert {:error, :invalid_grant} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id
               })
    end

    test "a disabled account cannot refresh, and re-enable restores the retained grant",
         %{account: account, client: client, tokens: tokens} do
      {_actor, _management_account, support_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 support_subject
               )

      params = %{"refresh_token" => tokens.refresh_token, "client_id" => client.id}
      assert {:error, :invalid_grant} = OAuth.refresh(params)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 false,
                 "Hold resolved",
                 support_subject
               )

      assert {:ok, _fresh} = OAuth.refresh(params)
    end

    test "rejects a refresh token presented by the wrong client",
         %{tokens: tokens} do
      other = register!("Other")

      assert {:error, :invalid_grant} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => other.id
               })
    end

    test "rejects a refresh whose resource mismatches the granted resource (RFC 8707)",
         %{client: client, tokens: tokens} do
      assert {:error, :invalid_target} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id,
                 "resource" => "https://other.example/mcp"
               })
    end

    test "a request missing the required params is :invalid_request, not a crash" do
      # The arity-1 fallback clause catches a param map lacking
      # refresh_token/client_id — a malformed token POST.
      assert {:error, :invalid_request} = OAuth.refresh(%{})
    end
  end

  describe "resolve_access_token/2" do
    test "rejects unknown / malformed tokens" do
      assert {:error, :invalid} = OAuth.resolve_access_token("emo-not-a-real-token", @resource)
      assert {:error, :invalid} = OAuth.resolve_access_token("garbage", @resource)
      assert {:error, :invalid} = OAuth.resolve_access_token(nil, @resource)
      assert {:error, :invalid} = OAuth.resolve_access_token("emo-not-a-real-token", nil)
    end
  end

  describe "resolve_access_token/2 invalidation paths" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      {:ok, tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      %{account: account, client: client, tokens: tokens}
    end

    test "an expired access token (past its TTL) resolves to :invalid", %{tokens: tokens} do
      # A live token resolves; backdating its access_expires_at past `now`
      # makes `live?/1` false, so resolution must fail closed rather than
      # hand back a subject for a token whose 1-hour window has elapsed.
      assert {:ok, _} = OAuth.resolve_access_token(tokens.access_token, @resource)

      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      Repo.update!(Ecto.Changeset.change(token, access_expires_at: past))

      assert {:error, :invalid} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end

    test "an access token whose pair was rotation-revoked by a refresh resolves to :invalid",
         %{client: client, tokens: tokens} do
      # Rotating the refresh token revokes the original token ROW (it holds
      # both the original access + refresh hashes). The fresh access token
      # resolves, but the rotated-away original must not — `not_revoked()`
      # filters its row out, so resolving the old access token fails closed.
      assert {:ok, fresh} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id
               })

      assert {:ok, _} = OAuth.resolve_access_token(fresh.access_token, @resource)
      assert {:error, :invalid} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end

    test "a token whose backing api-key is revoked after issuance resolves to :invalid",
         %{tokens: tokens} do
      # Revoking the backing key is the operator's OAuth off-switch. The
      # exchange/refresh-time checks are tested elsewhere; this asserts the
      # resolve path also fails closed — `peek_api_key_by_id` returns nil
      # for a revoked key, so the live access token no longer resolves.
      {:ok, %{api_key: key}} = OAuth.resolve_access_token(tokens.access_token, @resource)

      key
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :invalid} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end

    test "a token whose account is soft-deleted resolves to :invalid",
         %{account: account, tokens: tokens} do
      # `fetch_account_by_id` scopes by `not_deleted()`, so soft-deleting the
      # account makes it `{:error, :not_found}` inside resolve's `with`, which
      # falls through to `:invalid` — a token can't resolve into a dead tenant.
      assert {:ok, _} = OAuth.resolve_access_token(tokens.access_token, @resource)

      account
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :invalid} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end

    test "a disabled account's retained access token resolves generically as invalid",
         %{account: account, tokens: tokens} do
      {_actor, _management_account, support_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 support_subject
               )

      assert {:error, :invalid} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end

    test "cross-account isolation rides the backing key — a token only ever resolves to its own account",
         %{account: account, tokens: tokens} do
      # Stand up a SECOND account with its own consented token. Each token's
      # account_id + api_key_id are fixed at mint, so resolving account A's
      # token yields account A (never B), and vice versa — the backing-key
      # binding is the isolation boundary, not anything in the presented bearer.
      {_user_b, account_b, subject_b} = Fixtures.Subjects.owner_subject()
      client_b = register!("Other Tenant")
      {verifier_b, challenge_b} = pkce()
      code_b = issue!(subject_b, client_b, challenge_b)

      {:ok, tokens_b} =
        OAuth.exchange_code(%{
          "code" => code_b,
          "client_id" => client_b.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier_b
        })

      assert {:ok, %{account: acct_a, api_key: key_a}} =
               OAuth.resolve_access_token(tokens.access_token, @resource)

      assert {:ok, %{account: acct_b, api_key: key_b}} =
               OAuth.resolve_access_token(tokens_b.access_token, @resource)

      assert acct_a.id == account.id
      assert acct_b.id == account_b.id
      refute acct_a.id == account_b.id
      assert key_a.account_id == account.id
      assert key_b.account_id == account_b.id
    end

    test "rejects a token issued for another resource", %{tokens: tokens} do
      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      Repo.update!(Ecto.Changeset.change(token, resource: "https://other.example/mcp"))

      assert {:error, :invalid} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end

    test "rejects a token whose scope lacks mcp (fail-closed resource-server backstop)",
         %{tokens: tokens} do
      # `narrow_scope/1` always mints `mcp`, but the resource server must not
      # trust that: force the stored scope to `offline_access` only and the live
      # token no longer authenticates.
      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      Repo.update!(Ecto.Changeset.change(token, scope: "offline_access"))

      assert {:error, :invalid} = OAuth.resolve_access_token(tokens.access_token, @resource)
    end
  end

  describe "delete_expired_authorization_codes/1" do
    test "prunes codes past their expiry, keeps live ones" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      _code = issue!(subject, client, challenge)

      # The freshly-issued code has a 60s TTL — nothing to prune yet.
      assert 0 = OAuth.delete_expired_authorization_codes()

      # Treating "now" as 2 minutes ahead, that code is expired and pruned.
      future = DateTime.add(DateTime.utc_now(), 120, :second)
      assert 1 = OAuth.delete_expired_authorization_codes(future)

      # Idempotent — it's gone, a second sweep finds nothing.
      assert 0 = OAuth.delete_expired_authorization_codes(future)
    end
  end

  describe "delete_expired_tokens/1" do
    test "prunes fully expired grants but keeps a live refresh grant" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      {:ok, tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      past = DateTime.add(DateTime.utc_now(), -120, :second)

      Repo.update!(Ecto.Changeset.change(token, access_expires_at: past))
      assert 0 = OAuth.delete_expired_tokens()
      assert Repo.reload(token)

      Repo.update!(Ecto.Changeset.change(token, refresh_expires_at: past))
      assert 1 = OAuth.delete_expired_tokens()
      refute Repo.reload(token)
      assert 0 = OAuth.delete_expired_tokens()
    end
  end

  describe "delete_unused_clients/1" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject}
    end

    test "issue_code stamps last_authorized_at so a consented client is never swept",
         %{subject: subject} do
      client = register!()
      assert client.last_authorized_at == nil

      {_verifier, challenge} = pkce()
      _code = issue!(subject, client, challenge)

      assert %Client{last_authorized_at: %DateTime{}} = Repo.reload(client)
    end

    test "prunes only old never-authorized registrations", %{subject: subject} do
      # Never authorized + registered 40 days ago → pruned.
      stale = register!("Stale")
      backdate_registration(stale, -40)

      # Never authorized but recent → kept (still within the abandonment window).
      recent = register!("Recent")

      # Authorized (consent completed) + old → kept; last_authorized_at is set.
      consented = register!("Consented")
      {_verifier, challenge} = pkce()
      _code = issue!(subject, consented, challenge)
      backdate_registration(consented, -40)

      assert 1 = OAuth.delete_unused_clients()

      refute Repo.reload(stale)
      assert Repo.reload(recent)
      assert Repo.reload(consented)
    end
  end

  describe "supported_scopes/0" do
    test "advertises the scopes the server will grant" do
      scopes = OAuth.supported_scopes()
      assert is_list(scopes)
      assert "mcp" in scopes
    end
  end
end
