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

  # A client the authorization step materialized from its published metadata
  # document. Built through the document changeset so the row matches what a
  # real fetch would upsert, without standing up an HTTPS document server.
  defp metadata_document_client!(url) do
    document = %{
      "client_id" => url,
      "client_name" => "Metadata Client",
      "redirect_uris" => [@redirect]
    }

    {:ok, client} = document |> Client.Changeset.from_metadata_document(url) |> Repo.insert()
    client
  end

  defp backdate_registration(%Client{id: id}, days) do
    ts = DateTime.add(DateTime.utc_now(), days * 86_400, :second)
    {1, _} = Client.Query.by_id(id) |> Repo.update_all(set: [inserted_at: ts])
  end

  # Backdates an api_key's mint time so the abandoned-key sweep considers it at
  # the real default `now` — backdate_registration's sibling for keys.
  defp backdate_key(%ApiKey{id: id}, hours) do
    ts = DateTime.add(DateTime.utc_now(), hours * 3600, :second)
    queryable = ApiKey.Query.all() |> ApiKey.Query.by_id(id)
    {1, _} = Repo.update_all(queryable, set: [inserted_at: ts])
  end

  defp issue!(subject, client, challenge, opts \\ []) do
    params = authorization_params(challenge, %{"scope" => opts[:scope] || "mcp offline_access"})
    {:ok, code, @redirect} = OAuth.issue_code(client, params, subject)

    code
  end

  # A well-formed authorization request; `overrides` breaks exactly the field a
  # validation test is about.
  defp authorization_params(challenge, overrides \\ %{}) do
    Map.merge(
      %{
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp offline_access",
        "resource" => @resource
      },
      overrides
    )
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

    test "rejects a null byte in any stored string, rather than raising at the INSERT" do
      # Registration is public and unauthenticated, and JSON can carry ` `,
      # which decodes to a real NUL that String.valid?/1 still accepts. Postgres
      # refuses it (22021), so an unvalidated one raised Postgrex.Error past the
      # controller's changeset-only error branch: a 500 with database internals in
      # it for any anonymous caller.
      assert {:error, changeset} =
               OAuth.register_client(%{
                 "client_name" => "Test\0Client",
                 "redirect_uris" => [@redirect]
               })

      assert "must not contain null bytes" in errors_on(changeset).client_name

      assert {:error, changeset} =
               OAuth.register_client(%{
                 "client_name" => "Fine",
                 "scope" => "mcp\0offline_access",
                 "redirect_uris" => [@redirect]
               })

      assert "must not contain null bytes" in errors_on(changeset).scope

      assert {:error, changeset} =
               OAuth.register_client(%{
                 "client_name" => "Fine",
                 "redirect_uris" => [@redirect <> "\0"]
               })

      assert "must not contain null bytes" in errors_on(changeset).redirect_uris
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

    @tag :tmp_dir
    test "the pinned fetch still verifies TLS — an untrusted certificate is refused",
         %{tmp_dir: tmp_dir} do
      # The fetch was rewritten from Finch to Mint so it can connect to the exact
      # address `validate_destination/1` approved while carrying the URL's
      # hostname for SNI and certificate verification. Hand-rolling a connection
      # is how people accidentally turn verification off, so this drives the real
      # path — real listener, real handshake — against a certificate nothing
      # trusts, and requires it to fail.
      #
      # It also proves the rewrite reaches the handshake at all: a broken
      # connect would fail here for the wrong reason and this test could not
      # tell the difference, which is why the listener records the attempt.
      {:ok, listener} = start_metadata_listener(tmp_dir)
      on_exit(fn -> :ssl.close(listener.socket) end)

      Emisar.Config.put_override(:emisar, Emisar.OAuth.ClientMetadataDocument,
        allow_private_hosts: true
      )

      url = "https://localhost:#{listener.port}/client-metadata.json"
      assert {:error, :not_found} = OAuth.fetch_client(url)
      assert_receive {:tls_attempted, _outcome}, 5_000
      refute Repo.one(Client)
    end

    test "a metadata-document URL whose document cannot be retrieved is :not_found" do
      Emisar.Config.put_override(:emisar, Emisar.OAuth.ClientMetadataDocument,
        allow_private_hosts: false
      )

      assert {:error, :not_found} = OAuth.fetch_client("https://127.0.0.1/client-metadata.json")
      refute Repo.one(Client)
    end
  end

  describe "validate_authorization_request/2" do
    test "a well-formed request returns the callback proven against the registration" do
      client = register!()
      {_verifier, challenge} = pkce()

      assert OAuth.validate_authorization_request(client, authorization_params(challenge)) ==
               {:ok, @redirect}
    end

    test "an absent method means S256" do
      client = register!()
      {_verifier, challenge} = pkce()
      params = authorization_params(challenge) |> Map.delete("code_challenge_method")

      assert OAuth.validate_authorization_request(client, params) == {:ok, @redirect}
    end

    test "an unregistered or missing callback has nowhere safe to report to" do
      client = register!()
      {_verifier, challenge} = pkce()
      unregistered = authorization_params(challenge, %{"redirect_uri" => "https://evil.test/cb"})
      missing = authorization_params(challenge) |> Map.delete("redirect_uri")

      assert OAuth.validate_authorization_request(client, unregistered) ==
               {:error, :invalid_redirect_uri}

      assert OAuth.validate_authorization_request(client, missing) ==
               {:error, :invalid_redirect_uri}
    end

    test "the callback is checked before the protocol params" do
      # Both are wrong; the callback must decide, so the caller never learns it
      # may redirect an error to an origin the client never registered.
      client = register!()
      {_verifier, challenge} = pkce()

      params =
        authorization_params(challenge, %{
          "redirect_uri" => "https://evil.test/cb",
          "response_type" => "token"
        })

      assert OAuth.validate_authorization_request(client, params) ==
               {:error, :invalid_redirect_uri}
    end

    test "a protocol error rides back on the trusted callback" do
      client = register!()
      {_verifier, challenge} = pkce()

      bad_requests = %{
        "unsupported_response_type" => %{"response_type" => "token"},
        "invalid_request" => %{"code_challenge_method" => "plain"},
        "invalid_target" => %{"resource" => "https://other.example/mcp"}
      }

      for {error_code, overrides} <- bad_requests do
        params = authorization_params(challenge, overrides)

        assert OAuth.validate_authorization_request(client, params) ==
                 {:error, {:oauth, error_code, @redirect}}
      end
    end

    test "validating writes nothing" do
      client = register!()
      {_verifier, challenge} = pkce()

      assert {:ok, @redirect} =
               OAuth.validate_authorization_request(client, authorization_params(challenge))

      refute Repo.exists?(AuthorizationCode.Query.all())
      assert Repo.reload!(client).last_authorized_at == nil
    end
  end

  describe "issue_code/3 authorization gate" do
    test "a successful consent announces the backing key on the agents topic" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()

      Emisar.ApiKeys.subscribe_account_api_keys(account.id)
      _code = issue!(subject, client, challenge)

      # Consent commits the backing key → an open agents list reflows live.
      assert_receive {:list_changed, :api_key, "api_key.created", _key_id}, 500
    end

    test "a read-only viewer cannot consent — the OAuth flow can't mint an execute token they couldn't issue manually" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      # A viewer has view_api_keys but not issue_quick_key, so they can't mint
      # an API key in-product — and must not be able to via consent either.
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert {:error, :unauthorized} =
               OAuth.issue_code(client, authorization_params(challenge), viewer)
    end

    test "a suspended membership cannot mint a backing key from a stale subject" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.suspend_membership(membership)
      client = register!()
      {_verifier, challenge} = pkce()

      assert {:error, :not_found} =
               OAuth.issue_code(client, authorization_params(challenge), subject)

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
               OAuth.issue_code(client, authorization_params(challenge), subject)

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
               OAuth.issue_code(client, authorization_params(challenge), subject)

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a membership held by another operator mints nothing" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      peer = Fixtures.Users.create_user()

      peer_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: peer.id,
          role: "owner"
        )

      client = register!()
      {_verifier, challenge} = pkce()
      # The consent form's snapshot naming someone else's seat: the mint must
      # land on the ACTING operator's membership or not at all.
      borrowed = %{subject | membership_id: peer_membership.id}

      assert {:error, :not_found} =
               OAuth.issue_code(client, authorization_params(challenge), borrowed)

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a membership in another account mints nothing" do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      other_account = Fixtures.Accounts.create_account()

      other_membership =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: user.id,
          role: "owner"
        )

      client = register!()
      {_verifier, challenge} = pkce()
      borrowed = %{subject | membership_id: other_membership.id}

      assert {:error, :not_found} =
               OAuth.issue_code(client, authorization_params(challenge), borrowed)

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "an unregistered redirect_uri is refused with no trusted callback to report on" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      params = authorization_params(challenge, %{"redirect_uri" => "https://attacker.example/cb"})

      assert {:error, :invalid_redirect_uri} = OAuth.issue_code(client, params, subject)

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a caller cannot widen a persisted client's redirect registration" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      unregistered = "https://attacker.example/cb"
      stale_client = %{client | redirect_uris: [unregistered]}
      params = authorization_params(challenge, %{"redirect_uri" => unregistered})

      assert {:error, :invalid_redirect_uri} = OAuth.issue_code(stale_client, params, subject)

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a missing redirect_uri is refused" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      params = authorization_params(challenge) |> Map.delete("redirect_uri")

      assert {:error, :invalid_redirect_uri} = OAuth.issue_code(client, params, subject)

      refute Repo.exists?(ApiKey.Query.all())
    end

    test "a response_type other than code is refused on the trusted callback" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      params = authorization_params(challenge, %{"response_type" => "token"})

      assert OAuth.issue_code(client, params, subject) ==
               {:error, {:oauth, "unsupported_response_type", @redirect}}

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a missing or malformed PKCE challenge is refused" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()

      # Absent, empty, truncated, and outside the base64url alphabet — each is a
      # challenge no conformant S256 client would send.
      for bad <- [nil, "", String.slice(challenge, 0, 42), String.duplicate("+", 43)] do
        params = authorization_params(challenge, %{"code_challenge" => bad})

        assert OAuth.issue_code(client, params, subject) ==
                 {:error, {:oauth, "invalid_request", @redirect}},
               "expected invalid_request for #{inspect(bad)}"
      end

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a non-S256 challenge method is refused (MCP mandates S256)" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      params = authorization_params(challenge, %{"code_challenge_method" => "plain"})

      assert OAuth.issue_code(client, params, subject) ==
               {:error, {:oauth, "invalid_request", @redirect}}

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "a resource other than this MCP endpoint is refused" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      params = authorization_params(challenge, %{"resource" => "https://other.example/mcp"})

      assert OAuth.issue_code(client, params, subject) ==
               {:error, {:oauth, "invalid_target", @redirect}}

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "an account that requires SSO refuses a magic-link session" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      client = register!()
      {_verifier, challenge} = pkce()

      assert OAuth.issue_code(client, authorization_params(challenge), subject) ==
               {:error, :sso_required}

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "an account that requires MFA refuses an un-enrolled operator" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
      client = register!()
      {_verifier, challenge} = pkce()

      assert OAuth.issue_code(client, authorization_params(challenge), subject) ==
               {:error, :mfa_required}

      refute Repo.exists?(ApiKey.Query.all())
      refute Repo.exists?(AuthorizationCode.Query.all())
    end

    test "an active membership still mints a backing key" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()

      assert {:ok, _code, @redirect} =
               OAuth.issue_code(client, authorization_params(challenge), subject)

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

    test "a metadata-document client exchanges by presenting its URL, not the row id",
         %{subject: subject} do
      url = "https://app.example.com/oauth/client-metadata.json"
      client = metadata_document_client!(url)
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      # The row id must NOT authenticate the exchange: the client's identity is
      # the document URL it presented at authorization.
      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      assert {:ok, tokens} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => url,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      assert "emo-" <> _ = tokens.access_token
    end

    test "another client's metadata URL cannot exchange this client's code", %{subject: subject} do
      client = metadata_document_client!("https://app.example.com/oauth/client-metadata.json")
      metadata_document_client!("https://evil.example.com/oauth/client-metadata.json")
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => "https://evil.example.com/oauth/client-metadata.json",
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })
    end

    test "an unknown metadata URL never resolves to a client", %{subject: subject} do
      client = metadata_document_client!("https://app.example.com/oauth/client-metadata.json")
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => "https://never-seen.example.com/client.json",
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })
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
      assert Emisar.ApiKeys.key_usable?(key, DateTime.utc_now())
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

    test "rejects an expired authorization code", %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      # Push the 60s code TTL into the past under the row-hash the exchange locks
      # on — an expired code can no longer be exchanged (check_code_live fails it
      # closed, the same branch the abandoned-key sweep's safety proof leans on).
      past = DateTime.add(DateTime.utc_now(), -120, :second)

      {1, _} =
        AuthorizationCode.Query.all()
        |> AuthorizationCode.Query.by_code_hash(Emisar.Crypto.hash(code))
        |> Repo.update_all(set: [expires_at: past])

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })
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

    test "records the call on the backing key so the connection isn't 'never used'" do
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

      # Consent + exchange never touch last_used_at — only an actual MCP call
      # does, via the resolve path. Direct emk- auth records this; OAuth resolves
      # by id, so without this the agent row would read "never used" forever.
      assert %ApiKey{last_used_at: nil} = Repo.one(ApiKey)

      assert {:ok, %{api_key: %ApiKey{last_used_at: %DateTime{}}}} =
               OAuth.resolve_access_token(tokens.access_token, @resource)

      assert %ApiKey{last_used_at: %DateTime{}} = Repo.one(ApiKey)
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

  describe "delete_abandoned_backing_keys/1" do
    test "sweeps an abandoned consent — never exchanged, no token, past the grace window" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {_verifier, challenge} = pkce()
      _code = issue!(subject, client, challenge)

      # Consent minted a backing key with no token; inside the grace window
      # (an exchange could still be in flight) nothing is swept.
      assert %ApiKey{expires_at: nil, last_used_at: nil} = Repo.one(ApiKey)
      assert 0 = OAuth.delete_abandoned_backing_keys()

      # Past the grace window the key is unreachable (no token, raw secret was
      # discarded at mint) → swept, and its spent code cascades away with it.
      future = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      assert 1 = OAuth.delete_abandoned_backing_keys(future)
      refute Repo.one(ApiKey)
      refute Repo.one(AuthorizationCode)
    end

    test "keeps a live connection — a key with a token is never swept" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      client = register!()
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      {:ok, _tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      # Even far past the grace window, a key with a live token is a real
      # connection — deleting it would cascade-revoke the token, so it's left alone.
      future = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      assert 0 = OAuth.delete_abandoned_backing_keys(future)
      assert %ApiKey{} = Repo.one(ApiKey)
    end

    test "keeps a key whose only token is revoked — Token.Query.all() shields it, not just live tokens" do
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

      # Revoke the token but leave its ROW in place (the token sweep hasn't run).
      # reject_keys_with_tokens keys off Token.Query.all(), so a revoked-but-present
      # token still shields the backing key — a future "optimize to not_revoked"
      # would wrongly sweep it and cascade-delete the still-present token row.
      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      Repo.update!(Ecto.Changeset.change(token, revoked_at: DateTime.utc_now()))

      # Even well past the grace window, the surviving token row keeps the key.
      future = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      assert 0 = OAuth.delete_abandoned_backing_keys(future)
      assert %ApiKey{} = Repo.one(ApiKey)
    end

    test "sweeps a lapsed connection whose token is gone and was never used" do
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

      # Simulate the grant fully lapsing: the token sweep removed the row.
      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      Repo.delete!(token)

      # The key never recorded a call and now has no token → an unreachable dead
      # connection → swept.
      future = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      assert 1 = OAuth.delete_abandoned_backing_keys(future)
      refute Repo.one(ApiKey)
    end

    test "keeps a key that ran a command — last_used_at set is not 'never used'" do
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

      # A real MCP call recorded use on the key, then the grant lapsed (token gone).
      assert {:ok, _} = OAuth.resolve_access_token(tokens.access_token, @resource)
      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      Repo.delete!(token)

      # It has history (last_used_at set), so its row is kept even with no token.
      future = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      assert 0 = OAuth.delete_abandoned_backing_keys(future)
      assert %ApiKey{last_used_at: %DateTime{}} = Repo.one(ApiKey)
    end

    test "never sweeps a quick-ring key — its default expiry keeps it off the backing-key filter" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      {:ok, _raw, quick} = Emisar.ApiKeys.mint_quick_key(subject)

      # Age it two hours past the 1h grace so grace isn't what protects it: a
      # quick key survives because it carries a default expiry, and the sweep
      # only reclaims non-expiring (`is_nil(expires_at)`) :mcp backing keys.
      backdate_key(quick, -2)

      assert 0 = OAuth.delete_abandoned_backing_keys()
      assert Repo.reload(quick)
    end

    test "never sweeps an audit-export token, even non-expiring and aged past the grace window" do
      # An audit-export token is non-expiring like a backing key, so only its
      # :audit_export kind keeps it off the sweep — the candidate filter is
      # kind: :mcp, never merely "no expiry". Minting one needs the paid
      # export entitlement, so the account carries a Team subscription.
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team")

      {_raw, export} =
        Fixtures.ApiKeys.create_api_key(kind: :audit_export, account_id: account.id)

      assert export.kind == :audit_export
      assert is_nil(export.expires_at)

      backdate_key(export, -2)

      assert 0 = OAuth.delete_abandoned_backing_keys()
      assert Repo.reload(export)
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

  # A one-shot TLS listener serving a valid client-metadata document. The fetch
  # reaches it through the dev/test loopback path, which is the only way a
  # private address is allowed.
  defp start_metadata_listener(tmp_dir) do
    # Generated per run, not read from emisar_web/priv/cert: that pair is
    # gitignored dev output nothing in the repository creates, so it existed
    # only on machines that had once run phx.gen.cert and CI failed on :enoent.
    # Any self-signed pair does the job here — the assertion is that the fetch
    # refuses a certificate nothing trusts.
    certfile = Path.join(tmp_dir, "untrusted.pem")
    keyfile = Path.join(tmp_dir, "untrusted_key.pem")

    {_output, 0} =
      System.cmd(
        "openssl",
        ["req", "-x509", "-newkey", "rsa:2048", "-noenc", "-days", "1"] ++
          ["-subj", "/CN=localhost", "-keyout", keyfile, "-out", certfile],
        stderr_to_stdout: true
      )

    {:ok, socket} =
      :ssl.listen(0, [
        :binary,
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile),
        active: false,
        reuseaddr: true,
        packet: :raw
      ])

    {:ok, {_address, port}} = :ssl.sockname(socket)

    document =
      Jason.encode!(%{
        "client_id" => "https://localhost:#{port}/client-metadata.json",
        "client_name" => "Pinned Fetch Probe",
        "redirect_uris" => ["https://localhost/callback"]
      })

    parent = self()

    spawn_link(fn ->
      with {:ok, transport} <- :ssl.transport_accept(socket, 5_000),
           {:ok, connection} <- :ssl.handshake(transport, 5_000) do
        send(parent, {:tls_attempted, :handshake_completed})
        _ = :ssl.recv(connection, 0, 5_000)

        response =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " <>
            Integer.to_string(byte_size(document)) <> "\r\nConnection: close\r\n\r\n" <> document

        _ = :ssl.send(connection, response)
        :ssl.close(connection)
      else
        # The expected outcome: the client refused our certificate. Reporting it
        # is what proves the fetch actually reached the handshake.
        _refused -> send(parent, {:tls_attempted, :rejected_by_client})
      end
    end)

    {:ok, %{socket: socket, port: port}}
  end
end
