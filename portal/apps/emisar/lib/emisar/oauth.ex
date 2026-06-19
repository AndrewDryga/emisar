defmodule Emisar.OAuth do
  @moduledoc """
  Minimal OAuth 2.1 authorization server for remote MCP clients
  (Claude.ai, ChatGPT), implementing the subset the MCP authorization
  spec requires: Dynamic Client Registration (RFC 7591), authorization
  code + PKCE (S256), and refresh tokens.

  The RFC 8707 `resource` parameter is accepted and stored on the code +
  token, but is NOT yet enforced as an audience binding — there is one
  protected resource (the MCP endpoint) today, so audience confusion has
  no surface. Before adding a second protected resource, enforce
  `token.resource` against the canonical resource URI at resolve time.

  Tokens are backed by an `api_keys` row minted at consent, so the
  existing MCP auth + scoping + attribution logic is reused unchanged:
  `resolve_access_token/1` returns that backing key, which the MCP
  `:authenticate` plug assigns exactly as a static-bearer request.

  Token formats (all sha256-hashed at rest):

    * authorization code — `emoc-…`  (single-use, 60s)
    * access token       — `emo-…`   (1 hour)
    * refresh token      — `emor-…`  (30 days, rotated on use)
  """
  alias Ecto.Multi
  alias Emisar.{Accounts, ApiKeys, Audit, Crypto, Repo}
  alias Emisar.Auth
  alias Emisar.Auth.Subject
  alias Emisar.OAuth.{AuthorizationCode, Client, Token}

  @code_ttl_s 60
  @access_ttl_s 3_600
  @refresh_ttl_s 30 * 24 * 3_600

  @supported_scopes ~w(mcp offline_access)

  # -- Dynamic Client Registration (RFC 7591) -------------------------

  @doc """
  Internal — the DCR controller's registration endpoint (pre-auth; the
  request mints a new client, no Subject yet). Validates redirect URIs
  (https or localhost only), and stores the registration. Returns the
  client (its id is the OAuth client_id).
  """
  @spec register_client(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def register_client(params) do
    %{
      client_name: params["client_name"],
      redirect_uris: list_param(params, "redirect_uris"),
      grant_types: list_param(params, "grant_types", ["authorization_code", "refresh_token"]),
      response_types: list_param(params, "response_types", ["code"]),
      token_endpoint_auth_method: params["token_endpoint_auth_method"] || "none",
      scope: params["scope"] || "mcp offline_access",
      metadata: %{}
    }
    |> Client.Changeset.register()
    |> Repo.insert()
  end

  @doc "Internal — OAuth authorize/token controllers: load a client by its client_id (the client_id is the credential, resolved pre-Subject)."
  @spec fetch_client(String.t()) :: {:ok, Client.t()} | {:error, :not_found}
  def fetch_client(client_id) when is_binary(client_id) do
    # A connector can send any string here; guard the binary_id cast so a
    # malformed client_id is a clean "not found", not a 500.
    if Repo.valid_uuid?(client_id) do
      Client.Query.all() |> Client.Query.by_id(client_id) |> Repo.fetch(Client.Query, [])
    else
      {:error, :not_found}
    end
  end

  def fetch_client(_), do: {:error, :not_found}

  # -- Authorization (consent → code) ---------------------------------

  @doc """
  Called from the consent POST once a logged-in operator approves. Mints
  the backing MCP key for their membership and a single-use code bound
  to the PKCE challenge + redirect_uri + resource. Returns the raw code
  to hand back via the redirect.

  `subject` is the consenting operator; `client` the requesting client.
  """
  @spec issue_code(Client.t(), map(), Subject.t()) ::
          {:ok, String.t()} | {:error, term()}
  def issue_code(%Client{} = client, params, %Subject{} = subject) do
    # The backing key carries actions:read + actions:execute, so consenting
    # is exactly as privileged as minting an API key. Gate it on the same
    # permission the manual key-issue path requires — otherwise a read-only
    # viewer could walk the consent flow into an execute-capable token they
    # could never mint in-product (privilege escalation).
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             ApiKeys.Authorizer.issue_quick_key_permission()
           ) do
      account = subject.account
      user_id = Subject.actor_id(subject)
      membership_id = subject.membership_id
      key_name = "#{client.client_name || "MCP client"} (OAuth)"
      raw = "emoc-" <> Crypto.random_secret()

      Multi.new()
      |> Multi.run(:key, fn _repo, _changes ->
        ApiKeys.create_backing_key(account.id, user_id, membership_id, key_name)
      end)
      |> Multi.insert(:code, fn %{key: key} ->
        AuthorizationCode.Changeset.create(%{
          code_hash: Crypto.hash(raw),
          client_id: client.id,
          account_id: account.id,
          membership_id: membership_id,
          api_key_id: key.id,
          redirect_uri: params["redirect_uri"],
          code_challenge: params["code_challenge"],
          code_challenge_method: params["code_challenge_method"] || "S256",
          scope: narrow_scope(params["scope"]),
          resource: params["resource"],
          expires_at: secs_from_now(@code_ttl_s)
        })
      end)
      |> Multi.insert(:audit, fn %{key: key} ->
        Audit.Events.oauth_consent_granted(subject, client, key)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, _changes} -> {:ok, raw}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Token endpoint -------------------------------------------------

  @doc """
  Internal — the token controller's `authorization_code` grant (pre-auth;
  the code + PKCE verifier are the credential, resolved before a Subject
  exists). Validates: code exists + unused + unexpired, client matches,
  redirect_uri matches exactly, and the PKCE verifier hashes to the stored
  challenge (S256). Mints an access token (+ refresh token when
  offline_access was requested).
  """
  @spec exchange_code(map()) :: {:ok, map()} | {:error, atom()}
  def exchange_code(%{
        "code" => raw_code,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "code_verifier" => verifier
      })
      when is_binary(raw_code) and is_binary(client_id) and is_binary(verifier) do
    Multi.new()
    |> Multi.run(:code, fn repo, _changes ->
      # Locked read so two concurrent exchanges of the same code
      # serialize — the loser sees `used_at` set and gets :invalid_grant.
      code =
        AuthorizationCode.Query.all()
        |> AuthorizationCode.Query.by_code_hash(Crypto.hash(raw_code))
        |> AuthorizationCode.Query.lock_for_update()
        |> repo.one()

      with %AuthorizationCode{} <- code,
           :ok <- check_code_live(code),
           :ok <- check(code.client_id == client_id, :invalid_grant),
           :ok <- check(constant_eq(code.redirect_uri, redirect_uri), :invalid_grant),
           :ok <- check(valid_code_verifier?(verifier), :invalid_grant),
           :ok <- check(pkce_ok?(code, verifier), :invalid_grant),
           # Fail closed when the backing api_key was revoked / deleted / expired
           # between consent and exchange — revoking the key is the operator's
           # off-switch, so a code issued earlier must not still exchange (+ burn)
           # off a dead key. Mirrors the refresh path's check.
           :ok <- check(backing_key_usable?(code.api_key_id), :invalid_grant) do
        {:ok, code}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_grant}
      end
    end)
    # Burn the code (single use) before issuing tokens.
    |> Multi.run(:burned, fn repo, %{code: code} ->
      repo.update(AuthorizationCode.Changeset.consume(code))
    end)
    |> Multi.run(:tokens, fn _repo, %{code: code} -> mint_token_pair(code) end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{tokens: tokens}} -> {:ok, tokens}
      {:error, reason} -> {:error, reason}
    end
  end

  def exchange_code(_), do: {:error, :invalid_request}

  @doc """
  Internal — the token controller's `refresh_token` grant (pre-auth; the
  refresh token is the credential, resolved before a Subject exists).
  Validates the refresh token (live, matching client), rotates it
  (public-client requirement), and issues a fresh access + refresh pair
  from the same backing key.
  """
  @spec refresh(map()) :: {:ok, map()} | {:error, atom()}
  def refresh(%{"refresh_token" => raw, "client_id" => client_id})
      when is_binary(raw) and is_binary(client_id) do
    Multi.new()
    |> Multi.run(:token, fn repo, _changes ->
      token =
        Token.Query.all()
        |> Token.Query.not_revoked()
        |> Token.Query.by_refresh_hash(Crypto.hash(raw))
        |> Token.Query.lock_for_update()
        |> repo.one()

      with %Token{} <- token,
           :ok <- check(token.client_id == client_id, :invalid_grant),
           :ok <- check(live?(token.refresh_expires_at), :invalid_grant),
           # Fail closed when the backing api_key has been revoked / deleted /
           # expired since the grant was issued. Without this a refresh keeps
           # minting access tokens off a dead key — and revoking the key is the
           # operator's off-switch for an OAuth connection, so the refresh path
           # must honor it, not just the resolve path.
           :ok <- check(backing_key_usable?(token.api_key_id), :invalid_grant) do
        {:ok, token}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_grant}
      end
    end)
    # Rotate: revoke the old row, issue a new pair from the same key.
    |> Multi.run(:revoked, fn repo, %{token: token} ->
      repo.update(Token.Changeset.revoke(token))
    end)
    |> Multi.run(:tokens, fn _repo, %{token: token} ->
      mint_token_pair(%{
        client_id: token.client_id,
        account_id: token.account_id,
        membership_id: token.membership_id,
        api_key_id: token.api_key_id,
        scope: token.scope,
        resource: token.resource
      })
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{tokens: tokens}} -> {:ok, tokens}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh(_), do: {:error, :invalid_request}

  # -- Token resolution (MCP auth path) -------------------------------

  @doc """
  Internal — the MCP `:authenticate` plug (pre-auth; the bearer access
  token is the credential, resolved into the Subject downstream). Resolve a
  presented access token to its backing API key + account. Validates the
  token is live and not revoked, then loads the backing key (which carries
  scope + attribution). Returns `{:error, :invalid}` for anything off.
  """
  @spec resolve_access_token(String.t()) ::
          {:ok, %{api_key: term(), account: term(), token: Token.t()}} | {:error, :invalid}
  def resolve_access_token(raw) when is_binary(raw) do
    queryable =
      Token.Query.all()
      |> Token.Query.not_revoked()
      |> Token.Query.by_access_hash(Crypto.hash(raw))

    with %Token{} = token <- Repo.peek(queryable),
         true <- live?(token.access_expires_at),
         key when not is_nil(key) <- ApiKeys.peek_api_key_by_id(token.api_key_id),
         {:ok, account} <- Accounts.fetch_account_by_id(token.account_id) do
      {:ok, %{api_key: key, account: account, token: token}}
    else
      _ -> {:error, :invalid}
    end
  end

  def resolve_access_token(_), do: {:error, :invalid}

  @doc """
  Internal (Oban sweep) — delete authorization codes past their expiry.
  Codes are single-use, 60-second exchange artifacts (`emoc-`) with no
  audit or forensic value once expired, so they're pruned rather than
  retained. (Access/refresh tokens are deliberately NOT swept here — a
  revoked/expired token is a record of access that belongs under a
  retention policy, not this hygiene job.) Returns the count deleted.
  """
  def delete_expired_authorization_codes(now \\ DateTime.utc_now()) do
    {count, _} =
      AuthorizationCode.Query.all()
      |> AuthorizationCode.Query.expired_before(now)
      |> Repo.delete_all()

    count
  end

  @doc "Scopes this AS advertises in its metadata."
  def supported_scopes, do: @supported_scopes

  # -- Internal -------------------------------------------------------

  # Returns {:ok, token_response} | {:error, :server_error}. Runs inside the
  # exchange/refresh Multi, so an insert failure (e.g. a token-hash collision)
  # must surface as a value the token endpoint can shape into an OAuth error —
  # never an assertive match that raises and 500s the /oauth/token request.
  defp mint_token_pair(source) do
    access = "emo-" <> Crypto.random_secret()
    offline? = String.contains?(source.scope || "", "offline_access")
    refresh = if offline?, do: "emor-" <> Crypto.random_secret(), else: nil

    changeset =
      %{
        access_token_hash: Crypto.hash(access),
        refresh_token_hash: refresh && Crypto.hash(refresh),
        client_id: source.client_id,
        account_id: source.account_id,
        membership_id: source.membership_id,
        api_key_id: source.api_key_id,
        scope: source.scope,
        resource: source.resource,
        access_expires_at: secs_from_now(@access_ttl_s),
        refresh_expires_at: refresh && secs_from_now(@refresh_ttl_s)
      }
      |> Token.Changeset.create()

    case Repo.insert(changeset) do
      {:ok, _token} ->
        {:ok,
         %{
           access_token: access,
           token_type: "Bearer",
           expires_in: @access_ttl_s,
           refresh_token: refresh,
           scope: source.scope
         }}

      {:error, %Ecto.Changeset{}} ->
        {:error, :server_error}
    end
  end

  defp check_code_live(%AuthorizationCode{used_at: used}) when not is_nil(used),
    do: {:error, :invalid_grant}

  defp check_code_live(%AuthorizationCode{expires_at: exp}),
    do: if(live?(exp), do: :ok, else: {:error, :invalid_grant})

  defp pkce_ok?(
         %AuthorizationCode{code_challenge: challenge, code_challenge_method: "S256"},
         verifier
       ) do
    constant_eq(Crypto.pkce_s256_challenge(verifier), challenge)
  end

  # Plain method is not allowed (S256 required by MCP).
  defp pkce_ok?(_, _), do: false

  # RFC 7636 §4.1 — the code_verifier is 43–128 chars of the unreserved set.
  # Reject a malformed/too-short verifier (a non-conformant or malicious client
  # downgrading the PKCE entropy) before it's ever S256-hashed.
  defp valid_code_verifier?(verifier) do
    byte_size(verifier) in 43..128 and verifier =~ ~r/\A[A-Za-z0-9._~-]+\z/
  end

  defp list_param(params, key, default \\ []) do
    case params[key] do
      v when is_list(v) -> v
      v when is_binary(v) -> [v]
      _ -> default
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp constant_eq(a, b) when is_binary(a) and is_binary(b),
    do: Crypto.secure_compare(a, b)

  defp constant_eq(_, _), do: false

  defp live?(nil), do: false
  defp live?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) == :gt
  defp secs_from_now(s), do: DateTime.add(DateTime.utc_now(), s, :second)

  # `peek_api_key_by_id` returns nil unless the key passes `ApiKey.usable?`
  # (not revoked / deleted / expired) — the same liveness gate the access
  # token's resolve path uses.
  defp backing_key_usable?(api_key_id), do: not is_nil(ApiKeys.peek_api_key_by_id(api_key_id))

  # Keep only supported scopes from the (client-controlled) consent POST,
  # so a raw scope string can't persist something the consent UI didn't
  # show — and a future scope that maps to real capability on the backing
  # key can't be smuggled past `@supported_scopes`. Empty → the default.
  defp narrow_scope(raw) do
    (raw || "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&(&1 in @supported_scopes))
    |> case do
      [] -> "mcp offline_access"
      scopes -> Enum.join(scopes, " ")
    end
  end
end
