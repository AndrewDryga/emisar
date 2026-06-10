defmodule Emisar.OAuth do
  @moduledoc """
  Minimal OAuth 2.1 authorization server for remote MCP clients
  (Claude.ai, ChatGPT), implementing the subset the MCP authorization
  spec requires: Dynamic Client Registration (RFC 7591), authorization
  code + PKCE (S256), refresh tokens, and resource/audience binding
  (RFC 8707).

  Tokens are backed by an `api_keys` row minted at consent, so the
  existing MCP auth + scoping + attribution logic is reused unchanged:
  `resolve_access_token/1` returns that backing key, which the MCP
  `:authenticate` plug assigns exactly as a static-bearer request.

  Token formats (all sha256-hashed at rest):

    * authorization code — `emoc-…`  (single-use, 60s)
    * access token       — `emo-…`   (1 hour)
    * refresh token      — `emor-…`  (30 days, rotated on use)
  """
  alias Emisar.{Accounts, ApiKeys, Crypto, Repo}
  alias Emisar.Auth.{Authorizer, Subject}
  alias Emisar.OAuth.{AuthorizationCode, Client, Token}

  @code_ttl_s 60
  @access_ttl_s 3_600
  @refresh_ttl_s 30 * 24 * 3_600

  @supported_scopes ~w(mcp offline_access)

  # -- Dynamic Client Registration (RFC 7591) -------------------------

  @doc """
  Register a client from a DCR request body. Validates redirect URIs
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
  @spec issue_code(Subject.t(), Client.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def issue_code(%Subject{} = subject, %Client{} = client, params) do
    # The backing key carries actions:read + actions:execute, so consenting
    # is exactly as privileged as minting an API key. Gate it on the same
    # permission the manual key-issue path requires — otherwise a read-only
    # viewer could walk the consent flow into an execute-capable token they
    # could never mint in-product (privilege escalation).
    with :ok <-
           Authorizer.ensure_has_permissions(
             subject,
             ApiKeys.Authorizer.issue_quick_key_permission()
           ) do
      account = subject.account
      user_id = Subject.actor_id(subject)
      membership_id = subject.membership_id
      key_name = "#{client.client_name || "MCP client"} (OAuth)"

      Repo.transaction(fn ->
        {:ok, key} =
          ApiKeys.create_backing_key(account.id, user_id, membership_id, key_name)

        raw = "emoc-" <> Crypto.random_secret()

        {:ok, _code} =
          %{
            code_hash: Crypto.hash(raw),
            client_id: client.id,
            account_id: account.id,
            membership_id: membership_id,
            api_key_id: key.id,
            redirect_uri: params["redirect_uri"],
            code_challenge: params["code_challenge"],
            code_challenge_method: params["code_challenge_method"] || "S256",
            scope: params["scope"] || "mcp offline_access",
            resource: params["resource"],
            expires_at: secs_from_now(@code_ttl_s)
          }
          |> AuthorizationCode.Changeset.create()
          |> Repo.insert()

        raw
      end)
    end
  end

  # -- Token endpoint -------------------------------------------------

  @doc """
  Exchange an authorization code for tokens. Validates: code exists +
  unused + unexpired, client matches, redirect_uri matches exactly, and
  the PKCE verifier hashes to the stored challenge (S256). Mints an
  access token (+ refresh token when offline_access was requested).
  """
  @spec exchange_code(map()) :: {:ok, map()} | {:error, atom()}
  def exchange_code(%{
        "code" => raw_code,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "code_verifier" => verifier
      })
      when is_binary(raw_code) and is_binary(client_id) and is_binary(verifier) do
    Repo.transaction(fn ->
      with %AuthorizationCode{} = code <-
             AuthorizationCode.Query.all()
             |> AuthorizationCode.Query.by_code_hash(Crypto.hash(raw_code))
             |> AuthorizationCode.Query.lock_for_update()
             |> Repo.peek(),
           :ok <- check_code_live(code),
           :ok <- check(code.client_id == client_id, :invalid_grant),
           :ok <- check(constant_eq(code.redirect_uri, redirect_uri), :invalid_grant),
           :ok <- check(pkce_ok?(code, verifier), :invalid_grant) do
        # Burn the code (single use) before issuing tokens.
        {:ok, _} = code |> AuthorizationCode.Changeset.consume() |> Repo.update()

        mint_token_pair!(code)
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_grant)
      end
    end)
  end

  def exchange_code(_), do: {:error, :invalid_request}

  @doc """
  Refresh-token grant. Validates the refresh token (live, matching
  client), rotates it (public-client requirement), and issues a fresh
  access + refresh pair from the same backing key.
  """
  @spec refresh(map()) :: {:ok, map()} | {:error, atom()}
  def refresh(%{"refresh_token" => raw, "client_id" => client_id})
      when is_binary(raw) and is_binary(client_id) do
    Repo.transaction(fn ->
      with %Token{} = tok <-
             Token.Query.all()
             |> Token.Query.not_revoked()
             |> Token.Query.by_refresh_hash(Crypto.hash(raw))
             |> Repo.peek(),
           :ok <- check(tok.client_id == client_id, :invalid_grant),
           :ok <- check(live?(tok.refresh_expires_at), :invalid_grant) do
        # Rotate: revoke the old row, issue a new pair from the same key.
        {:ok, _} = tok |> Token.Changeset.revoke() |> Repo.update()

        mint_token_pair!(%{
          client_id: tok.client_id,
          account_id: tok.account_id,
          membership_id: tok.membership_id,
          api_key_id: tok.api_key_id,
          scope: tok.scope,
          resource: tok.resource
        })
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_grant)
      end
    end)
  end

  def refresh(_), do: {:error, :invalid_request}

  # -- Token resolution (MCP auth path) -------------------------------

  @doc """
  Resolve a presented access token to its backing API key + account.
  Used by the MCP `:authenticate` plug. Validates the token is live and
  not revoked, then loads the backing key (which carries scope +
  attribution). Returns `{:error, :invalid}` for anything off.
  """
  @spec resolve_access_token(String.t()) ::
          {:ok, %{api_key: term(), account: term(), token: Token.t()}} | {:error, :invalid}
  def resolve_access_token(raw) when is_binary(raw) do
    with %Token{} = tok <-
           Token.Query.all()
           |> Token.Query.not_revoked()
           |> Token.Query.by_access_hash(Crypto.hash(raw))
           |> Repo.peek(),
         true <- live?(tok.access_expires_at),
         key when not is_nil(key) <- ApiKeys.peek_api_key_by_id(tok.api_key_id),
         {:ok, account} <- Accounts.fetch_account_by_id(tok.account_id) do
      {:ok, %{api_key: key, account: account, token: tok}}
    else
      _ -> {:error, :invalid}
    end
  end

  def resolve_access_token(_), do: {:error, :invalid}

  @doc "Scopes this AS advertises in its metadata."
  def supported_scopes, do: @supported_scopes

  # -- Internal -------------------------------------------------------

  defp mint_token_pair!(src) do
    access = "emo-" <> Crypto.random_secret()
    offline? = String.contains?(src.scope || "", "offline_access")
    refresh = if offline?, do: "emor-" <> Crypto.random_secret(), else: nil

    {:ok, _token} =
      %{
        access_token_hash: Crypto.hash(access),
        refresh_token_hash: refresh && Crypto.hash(refresh),
        client_id: src.client_id,
        account_id: src.account_id,
        membership_id: src.membership_id,
        api_key_id: src.api_key_id,
        scope: src.scope,
        resource: src.resource,
        access_expires_at: secs_from_now(@access_ttl_s),
        refresh_expires_at: refresh && secs_from_now(@refresh_ttl_s)
      }
      |> Token.Changeset.create()
      |> Repo.insert()

    %{
      access_token: access,
      token_type: "Bearer",
      expires_in: @access_ttl_s,
      refresh_token: refresh,
      scope: src.scope
    }
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
end
