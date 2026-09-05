defmodule Emisar.OAuth do
  @moduledoc """
  Minimal OAuth 2.1 authorization server for remote MCP clients
  (Claude.ai, ChatGPT), implementing the subset the MCP authorization
  spec requires: Dynamic Client Registration (RFC 7591), authorization
  code + PKCE (S256), and refresh tokens.

  The RFC 8707 `resource` parameter is stored on the code + token. The
  MCP bearer boundary supplies its canonical resource URI to
  `resolve_access_token/2`, which validates that the token was issued for
  that resource before resolving its backing key.

  Tokens are backed by an `api_keys` row minted at consent, so the
  existing MCP auth + scoping + attribution logic is reused unchanged:
  `resolve_access_token/2` returns that backing key, which the MCP
  `:authenticate` plug assigns exactly as a static-bearer request.

  Token formats (all sha256-hashed at rest):

    * authorization code — `emoc-…`  (single-use, 60s)
    * access token       — `emo-…`   (1 hour)
    * refresh token      — `emor-…`  (30 days, rotated on use)
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, ApiKeys, Audit, Crypto, PublicUrl, Repo, Users}
  alias Emisar.Auth
  alias Emisar.Auth.Subject
  alias Emisar.OAuth.{AuthorizationCode, Client, ClientMetadataDocument, Jobs, Token}

  @code_ttl_s 60
  @access_ttl_s 3_600
  @refresh_ttl_s 30 * 24 * 3_600
  # A dynamically-registered client that never completed consent is abandoned
  # after this long — the daily sweep prunes it so `oauth_clients` doesn't grow
  # one orphan row per drive-by registration.
  @unused_client_ttl_s 30 * 24 * 3_600

  # Matches the audit and run retention jobs. Sized so one statement's row locks
  # stay short on a table the authorization path reads.
  @sweep_batch 5_000

  # A consent-minted backing key with no token is only swept once it's older than
  # this. Comfortably exceeds the 60s code TTL so an in-flight consent (exchange
  # still pending) is never reclaimed; past it, an expired code can no longer be
  # exchanged, so no token will ever appear.
  @abandoned_key_grace_s 60 * 60

  @supported_scopes ~w(mcp offline_access)

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    Supervisor.init([Jobs.Cleanup], strategy: :one_for_one)
  end

  # -- Dynamic Client Registration (RFC 7591) -------------------------

  @cursor_redirect_uri "cursor://anysphere.cursor-mcp/oauth/callback"

  @doc """
  Internal — the DCR controller's registration endpoint (pre-auth; the
  request mints a new client, no Subject yet). Validates HTTPS, native-app,
  and loopback redirect URIs, then stores the registration. Returns the client
  (its id is the OAuth client_id).
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
      metadata: registration_metadata(params)
    }
    |> Client.Changeset.register()
    |> Repo.insert()
  end

  # The stored metadata is server-shaped — only the registration fields we
  # honor enter the jsonb, never the client's arbitrary payload. The OIDC
  # `application_type` (MCP SEP-837) decides which redirect-URI shapes the
  # changeset accepts.
  defp registration_metadata(%{"application_type" => application_type})
       when is_binary(application_type),
       do: %{"application_type" => application_type}

  # Cursor 3.x omits application_type from DCR despite registering its native
  # callback. Record the exact known callback as native; look-alike URIs remain
  # unclassified and fail redirect validation.
  defp registration_metadata(params) do
    if @cursor_redirect_uri in list_param(params, "redirect_uris") do
      %{"application_type" => "native"}
    else
      %{}
    end
  end

  @doc """
  Internal — the OAuth authorize controller: resolve a client by the
  `client_id` it presented (the client_id is the credential, resolved
  pre-Subject).

  An HTTPS URL is a Client ID Metadata Document: its document is fetched and
  validated on every authorization, and the resulting row is upserted so the
  live document — not a months-old registration — decides the client's name and
  redirect URIs. Any other value is a Dynamic Client Registration id.
  """
  @spec fetch_client(String.t()) :: {:ok, Client.t()} | {:error, :not_found}
  def fetch_client(client_id) when is_binary(client_id) do
    if ClientMetadataDocument.metadata_url?(client_id) do
      fetch_metadata_document_client(client_id)
    else
      fetch_registered_client(client_id)
    end
  end

  def fetch_client(_), do: {:error, :not_found}

  defp fetch_registered_client(client_id) do
    # A connector can send any string here; guard the binary_id cast so a
    # malformed client_id is a clean "not found", not a 500.
    if Repo.valid_uuid?(client_id) do
      Client.Query.all() |> Client.Query.by_id(client_id) |> Repo.fetch(Client.Query, [])
    else
      {:error, :not_found}
    end
  end

  defp fetch_metadata_document_client(url) do
    with {:ok, document} <- ClientMetadataDocument.fetch(url),
         changeset = Client.Changeset.from_metadata_document(document, url),
         {:ok, client} <- upsert_metadata_document_client(changeset) do
      {:ok, client}
    else
      _reason -> {:error, :not_found}
    end
  end

  # Keyed by the document URL, so a re-authorization refreshes the same row
  # rather than accumulating one per consent. `last_authorized_at` is left out
  # of the replace list: it is our own consent history, not the client's to
  # reset by republishing its document.
  defp upsert_metadata_document_client(changeset) do
    Repo.insert(changeset,
      on_conflict:
        {:replace,
         [
           :client_name,
           :redirect_uris,
           :grant_types,
           :response_types,
           :scope,
           :metadata,
           :updated_at
         ]},
      conflict_target:
        {:unsafe_fragment, "(client_id_metadata_url) WHERE client_id_metadata_url IS NOT NULL"},
      returning: true
    )
  end

  # A grant records the client's row id; the token endpoint receives whatever
  # identifier the client presents. Compare against that client's ONE canonical
  # identity: a metadata-document client is addressed only by its document URL,
  # a registered client only by its issued id. Never dereference the presented
  # URL here — a code exists only because authorization already fetched and
  # validated the document.
  defp presented_client_matches?(repo, granted_client_id, presented) do
    queryable = Client.Query.all() |> Client.Query.by_id(granted_client_id)

    case repo.one(queryable) do
      %Client{client_id_metadata_url: url} when is_binary(url) -> url == presented
      %Client{id: id} -> id == presented
      nil -> false
    end
  end

  # -- Authorization (consent → code) ---------------------------------

  @doc """
  Internal — the consent GET's request check (pre-auth as to the client; the
  operator's session is the web boundary's concern). Writes nothing, so the
  consent screen can render for a request the operator may still deny.

  The callback is checked FIRST, against the client's own registration: an
  unregistered or absent `redirect_uri` returns `{:error, :invalid_redirect_uri}`
  and the caller must render the failure locally — we have no trusted place to
  send the operator. Once the callback is proven, a protocol error rides back on
  it as `{:error, {:oauth, error_code, trusted_redirect_uri}}`. A well-formed
  request returns `{:ok, trusted_redirect_uri}`.
  """
  @spec validate_authorization_request(Client.t(), map()) ::
          {:ok, String.t()}
          | {:error, :invalid_redirect_uri | {:oauth, String.t(), String.t()}}
  def validate_authorization_request(%Client{} = client, params) do
    with {:ok, redirect_uri} <- trusted_redirect_uri(client, params["redirect_uri"]) do
      case ensure_request_supported(params) do
        :ok -> {:ok, redirect_uri}
        {:error, error_code} -> {:error, {:oauth, error_code, redirect_uri}}
      end
    end
  end

  @doc """
  Called from the consent POST once a logged-in operator approves. Mints the
  backing MCP key for their membership and a single-use code bound to the PKCE
  challenge + redirect_uri + resource. Returns the raw code together with the
  callback it may be delivered to, proven against the client's registration.

  `client` and `subject` are consent-screen SNAPSHOTS, never the authority: the
  request is validated against the locked client row, and the account,
  membership, user, and role are re-read under row locks, so a role change, a
  revoked seat, or an account security control that landed since the screen
  rendered blocks the mint before anything is written. Returns
  `{:error, :unauthorized}` when the current role can't issue keys,
  `{:error, :sso_required | :mfa_required}` when the account's controls aren't
  satisfied, and `{:error, :not_found}` when the seat is gone or isn't the
  operator's.
  """
  @spec issue_code(Client.t(), map(), Subject.t()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def issue_code(%Client{} = client, params, %Subject{} = subject) do
    # IL-3's pre-DB gate. The backing key carries actions:read + actions:execute,
    # so consenting is exactly as privileged as minting an API key — otherwise a
    # read-only viewer could walk the consent flow into an execute-capable token
    # they could never mint in-product (privilege escalation). The locked-row
    # re-check below is what makes it authoritative.
    with :ok <- ensure_can_issue_backing_key(subject) do
      raw = "emoc-" <> Crypto.random_secret()

      Multi.new()
      |> Multi.run(:client, fn repo, _changes ->
        fetch_and_lock_client(client.id, repo)
      end)
      |> Multi.run(:redirect_uri, fn _repo, %{client: client} ->
        validate_authorization_request(client, params)
      end)
      |> Multi.run(:account, fn repo, _changes ->
        Accounts.fetch_and_lock_account(subject.account.id, repo: repo)
      end)
      |> Multi.run(:membership, fn repo, %{account: account} ->
        fetch_and_lock_consenting_membership(account.id, subject, repo)
      end)
      |> Multi.run(:user, fn repo, %{membership: membership} ->
        Users.fetch_and_lock_user_by_id(membership.user_id, repo)
      end)
      |> Multi.run(:subject, fn _repo, changes ->
        rebuild_consenting_subject(changes, subject)
      end)
      |> Multi.run(:key, fn _repo, changes ->
        mint_backing_key(changes)
      end)
      |> Multi.insert(:code, &authorization_code_changeset(&1, params, raw))
      |> Multi.insert(:audit, fn %{subject: subject, client: client, key: key} ->
        Audit.Events.oauth_consent_granted(subject, client, key)
      end)
      # Stamp the client so it's never swept as an abandoned registration.
      |> Multi.update(:authorized_client, fn %{client: client} ->
        Client.Changeset.mark_authorized(client, DateTime.utc_now())
      end)
      # Announce the new backing key so an open agents list reflows to show the
      # connection the moment consent lands, not on the next 5s tick.
      |> Repo.commit_multi(after_commit: &ApiKeys.broadcast_backing_key_created(&1.key))
      |> case do
        {:ok, %{redirect_uri: redirect_uri}} -> {:ok, raw, redirect_uri}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_and_lock_client(client_id, repo) do
    Client.Query.all()
    |> Client.Query.by_id(client_id)
    |> Client.Query.lock_for_update()
    |> repo.fetch(Client.Query, [])
  end

  # The consenting operator's OWN seat under the locked account. The subject is a
  # snapshot, so the membership it names must still be live AND still belong to
  # that operator — a swapped `membership_id` must never mint a key on someone
  # else's seat, and a gone seat is indistinguishable from one that never was.
  defp fetch_and_lock_consenting_membership(account_id, %Subject{} = subject, repo) do
    with {:ok, membership} <-
           Accounts.fetch_and_lock_membership(account_id, subject.membership_id, repo: repo),
         :ok <- check(membership.user_id == Subject.actor_id(subject), :not_found) do
      {:ok, membership}
    end
  end

  # Rebuild the caller from the locked rows, carrying this request's provenance
  # (context + how the operator signed in) so the audit row stays accurate. The
  # key-issue permission and the account's require_sso / require_mfa controls are
  # then judged on the CURRENT role and settings, not the consent screen's.
  defp rebuild_consenting_subject(
         %{user: user, account: account, membership: membership},
         %Subject{} = subject
       ) do
    fresh =
      Subject.for_user(user, account, membership, subject.context,
        auth_method: subject.auth_method,
        mfa: subject.mfa,
        mfa_enrollment_verified_at: subject.mfa_enrollment_verified_at,
        user_identity_id: subject.user_identity_id
      )

    with :ok <- ensure_can_issue_backing_key(fresh),
         :ok <- Accounts.ensure_account_compliant(account, fresh) do
      {:ok, fresh}
    end
  end

  defp ensure_can_issue_backing_key(%Subject{} = subject) do
    Auth.Authorizer.ensure_has_permissions(
      subject,
      ApiKeys.Authorizer.issue_quick_key_permission()
    )
  end

  defp mint_backing_key(%{account: account, membership: membership, client: client}) do
    name = "#{client.client_name || "MCP client"} (OAuth)"

    ApiKeys.create_backing_key(account.id, membership.user_id, membership.id, name)
  end

  defp authorization_code_changeset(changes, params, raw) do
    %{account: account, membership: membership, client: client, key: key} = changes

    AuthorizationCode.Changeset.create(%{
      code_hash: Crypto.hash(raw),
      client_id: client.id,
      account_id: account.id,
      membership_id: membership.id,
      api_key_id: key.id,
      redirect_uri: changes.redirect_uri,
      code_challenge: params["code_challenge"],
      code_challenge_method: params["code_challenge_method"] || "S256",
      scope: narrow_scope(params["scope"]),
      resource: params["resource"],
      expires_at: secs_from_now(@code_ttl_s)
    })
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
  def exchange_code(
        %{
          "code" => raw_code,
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "code_verifier" => verifier
        } = params
      )
      when is_binary(raw_code) and is_binary(client_id) and is_binary(verifier) do
    Multi.new()
    |> Multi.run(:code, fn repo, _changes ->
      # Locked read so two concurrent exchanges of the same code
      # serialize — the loser sees `used_at` set and gets :invalid_grant.
      code_query =
        AuthorizationCode.Query.all()
        |> AuthorizationCode.Query.by_code_hash(Crypto.hash(raw_code))
        |> AuthorizationCode.Query.lock_for_update()

      with {:ok, code} <- repo.fetch(code_query, AuthorizationCode.Query),
           :ok <- check_code_live(code),
           :ok <-
             check(presented_client_matches?(repo, code.client_id, client_id), :invalid_grant),
           :ok <- check(code.redirect_uri == redirect_uri, :invalid_grant),
           :ok <- check(resource_param_ok?(code.resource, params["resource"]), :invalid_target),
           :ok <- check(valid_code_verifier?(verifier), :invalid_grant),
           :ok <- check(pkce_ok?(code, verifier), :invalid_grant),
           # Fail closed when the backing api_key was revoked / deleted / expired
           # between consent and exchange — revoking the key is the operator's
           # off-switch, so a code issued earlier must not still exchange (+ burn)
           # off a dead key. Mirrors the refresh path's check.
           :ok <- check(backing_key_usable?(code.api_key_id), :invalid_grant) do
        {:ok, code}
      else
        {:error, :not_found} -> {:error, :invalid_grant}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.run(:account, fn repo, %{code: code} ->
      case Accounts.fetch_and_lock_account(code.account_id, repo: repo) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:error, :invalid_grant}
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
  from the same backing key. Reuse of a still-current spent refresh token
  revokes the backing connection and every active pair derived from it.
  """
  @spec refresh(map()) :: {:ok, map()} | {:error, atom()}
  def refresh(%{"refresh_token" => raw, "client_id" => client_id} = params)
      when is_binary(raw) and is_binary(client_id) do
    refresh_hash = Crypto.hash(raw)

    Multi.new()
    # This first read authorizes nothing. It only finds the account whose lock
    # orders all refreshes before the exact token is re-read under its own lock.
    # Account-first ordering lets a spent predecessor revoke every successor
    # without deadlocking a concurrent refresh of one of those successors.
    |> Multi.run(:refresh_candidate, fn repo, _changes ->
      candidate_query =
        Token.Query.all()
        |> Token.Query.by_refresh_hash(refresh_hash)

      case repo.fetch(candidate_query, Token.Query) do
        {:ok, token} -> {:ok, token}
        {:error, :not_found} -> {:error, :invalid_grant}
      end
    end)
    |> Multi.run(:account, fn repo, %{refresh_candidate: candidate} ->
      case Accounts.fetch_and_lock_account(candidate.account_id, repo: repo) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:error, :invalid_grant}
      end
    end)
    |> Multi.run(:token, fn repo, %{refresh_candidate: candidate} ->
      token =
        Token.Query.all()
        |> Token.Query.by_id(candidate.id)
        |> Token.Query.by_refresh_hash(refresh_hash)
        |> Token.Query.lock_for_update()
        |> repo.one()

      classify_refresh_token(repo, token, client_id, params["resource"])
    end)
    |> Multi.merge(&refresh_multi/1)
    |> Repo.commit_multi(after_commit: &after_refresh_committed/1)
    |> case do
      {:ok, %{tokens: tokens}} -> {:ok, tokens}
      {:ok, %{refresh_reuse: :detected}} -> {:error, :invalid_grant}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh(_), do: {:error, :invalid_request}

  defp classify_refresh_token(_repo, nil, _client_id, _resource),
    do: {:error, :invalid_grant}

  defp classify_refresh_token(repo, %Token{} = token, client_id, resource) do
    with :ok <- check(live?(token.refresh_expires_at), :invalid_grant),
         :ok <- check(presented_client_matches?(repo, token.client_id, client_id), :invalid_grant),
         :ok <- check(resource_param_ok?(token.resource, resource), :invalid_target) do
      if is_nil(token.revoked_at) do
        with :ok <- check(backing_key_usable?(token.api_key_id), :invalid_grant) do
          {:ok, %{state: :live, token: token}}
        end
      else
        {:ok, %{state: :reused, token: token}}
      end
    end
  end

  defp refresh_multi(%{token: %{state: :live, token: token}}) do
    Multi.new()
    |> Multi.update(:revoked, Token.Changeset.revoke(token))
    |> Multi.run(:tokens, fn _repo, _changes ->
      mint_token_pair(%{
        client_id: token.client_id,
        account_id: token.account_id,
        membership_id: token.membership_id,
        api_key_id: token.api_key_id,
        scope: token.scope,
        resource: token.resource
      })
    end)
  end

  defp refresh_multi(%{token: %{state: :reused, token: token}}) do
    Multi.new()
    |> ApiKeys.put_oauth_refresh_reuse_revocation(token.api_key_id)
    |> Multi.run(:refresh_reuse, fn repo, %{oauth_backing_key_revocation: revocation} ->
      now = DateTime.utc_now()

      Token.Query.all()
      |> Token.Query.by_api_key_ids([token.api_key_id])
      |> Token.Query.not_revoked()
      |> repo.update_all(set: [revoked_at: now, updated_at: now])

      with :ok <- maybe_audit_refresh_reuse(repo, token, revocation) do
        {:ok, :detected}
      end
    end)
  end

  defp maybe_audit_refresh_reuse(repo, token, %{key: key, revoked?: true}) do
    case repo.insert(Audit.Events.oauth_refresh_token_reused(token, key)) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_audit_refresh_reuse(_repo, _token, %{revoked?: false}), do: :ok

  defp after_refresh_committed(%{
         oauth_backing_key_revocation: %{key: key, revoked?: true}
       }),
       do: ApiKeys.broadcast_backing_key_revoked(key)

  defp after_refresh_committed(_changes), do: :ok

  # -- Token resolution (MCP auth path) -------------------------------

  @doc """
  Internal — the MCP `:authenticate` plug (pre-auth; the bearer access
  token is the credential, resolved into the Subject downstream). Resolve a
  presented access token to its backing API key + account for `resource`.
  Validates the token is live, not revoked, carries the `mcp` scope, and is
  audience-bound to that resource before loading the backing key (which carries
  attribution). Returns `{:error, :invalid}` for anything off.
  """
  @spec resolve_access_token(String.t(), String.t()) ::
          {:ok, %{api_key: term(), account: term(), token: Token.t()}} | {:error, :invalid}
  def resolve_access_token(raw, resource) when is_binary(raw) and is_binary(resource) do
    queryable =
      Token.Query.all()
      |> Token.Query.not_revoked()
      |> Token.Query.by_access_hash(Crypto.hash(raw))

    with %Token{} = token <- Repo.peek(queryable),
         true <- live?(token.access_expires_at),
         true <- resource_matches?(token.resource, resource),
         key when not is_nil(key) <- ApiKeys.peek_api_key_by_id(token.api_key_id),
         {:ok, account} <- Accounts.fetch_account_by_id(token.account_id) do
      # Record the call on the backing key. Direct `emk-` auth bumps this in
      # `peek_api_key_by_secret/1`; the OAuth path resolves by id, so it must
      # record here or the connection's agent row stays "never used" forever.
      used_key = ApiKeys.record_backing_key_usage(key)
      {:ok, %{api_key: used_key, account: account, token: token}}
    else
      _ -> {:error, :invalid}
    end
  end

  def resolve_access_token(_, _), do: {:error, :invalid}

  @doc """
  Internal — the OAuth cleanup sweep. Consent mints the backing MCP key up front
  (`issue_code/3`); an abandoned consent, or a lapsed connection that was never
  used, then leaves a permanent "(OAuth)" agent row. Removes OAuth backing keys
  that never authenticated a call and can no longer be reached: a key with no
  token is unreachable (the raw `emk-` secret is discarded at mint, so only an
  `emo-` token resolves it), and past the grace window no token will ever appear.
  A key that actually ran commands keeps its row (`last_used_at` set), and a key
  with any live token is left alone. The api_keys FK cascade clears any spent code
  along with it. Returns the count of keys deleted.
  """
  def delete_abandoned_backing_keys(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@abandoned_key_grace_s, :second)

    candidate_ids = ApiKeys.list_stale_oauth_backing_key_ids(cutoff)

    ApiKeys.delete_backing_keys(reject_keys_with_tokens(candidate_ids))
  end

  # A key with any token row is still a reachable (live or refreshable)
  # connection — deleting it would cascade-revoke that token. Tokens are
  # OAuth-owned, so this guard lives here, not in the ApiKeys candidate query.
  defp reject_keys_with_tokens([]), do: []

  defp reject_keys_with_tokens(candidate_ids) do
    keyed =
      Token.Query.all()
      |> Token.Query.by_api_key_ids(candidate_ids)
      |> Token.Query.select_api_key_ids()
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(candidate_ids, &MapSet.member?(keyed, &1))
  end

  @doc """
  Internal — delete authorization codes past their expiry. Codes are
  single-use, 60-second exchange artifacts (`emoc-`) with no audit or forensic
  value once expired, so they're pruned rather than retained. Returns the count
  deleted.
  """
  def delete_expired_authorization_codes(now \\ DateTime.utc_now()) do
    sweep_in_batches(fn ->
      ids = AuthorizationCode.Query.prunable_ids(now, @sweep_batch) |> Repo.all()
      {count, _} = ids |> AuthorizationCode.Query.by_ids() |> Repo.delete_all()
      {count, length(ids)}
    end)
  end

  @doc """
  Internal — delete OAuth token rows after their complete grant expires.
  Refresh-capable rows stay until `refresh_expires_at`; access-only rows are
  eligible after `access_expires_at`. Returns the count deleted.
  """
  def delete_expired_tokens(now \\ DateTime.utc_now()) do
    sweep_in_batches(fn ->
      ids = Token.Query.prunable_ids(now, @sweep_batch) |> Repo.all()
      {count, _} = ids |> Token.Query.by_ids() |> Repo.delete_all()
      {count, length(ids)}
    end)
  end

  # All three sweeps page like the audit and run retention jobs. An unbounded
  # `delete_all` takes row locks on everything it matches in ONE statement, so a
  # backlog — an outage, a disabled job, a burst of drive-by registrations —
  # turns the cleanup into a long lock on a table the authorization path reads.
  defp sweep_in_batches(delete_page) do
    {deleted, page} = delete_page.()

    if page == @sweep_batch do
      deleted + sweep_in_batches(delete_page)
    else
      deleted
    end
  end

  @doc """
  Internal — delete dynamically-registered clients that never
  completed consent and were registered over 30 days ago. A client is stamped
  `last_authorized_at` the moment an operator consents (`issue_code/3`), so this
  only ever removes abandoned drive-by registrations — never a live connection.
  Returns the count deleted.
  """
  def delete_unused_clients(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@unused_client_ttl_s, :second)

    # Paged like its two siblings, and for their exact reason: this is the sweep
    # that exists FOR drive-by registrations, on the one table `fetch_client/1`
    # reads on every `/oauth/authorize`.
    sweep_in_batches(fn ->
      ids = Client.Query.prunable_ids(cutoff, @sweep_batch) |> Repo.all()
      {count, _} = ids |> Client.Query.by_ids() |> Repo.delete_all()
      {count, length(ids)}
    end)
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
    Crypto.secure_compare(Crypto.pkce_s256_challenge(verifier), challenge)
  end

  # Plain method is not allowed (S256 required by MCP).
  defp pkce_ok?(_, _), do: false

  # RFC 7636 §4.1 — the code_verifier is 43–128 chars of the unreserved set.
  # Reject a malformed/too-short verifier (a non-conformant or malicious client
  # downgrading the PKCE entropy) before it's ever S256-hashed.
  defp valid_code_verifier?(verifier) do
    byte_size(verifier) in 43..128 and verifier =~ ~r/\A[A-Za-z0-9._~-]+\z/
  end

  # The callback the code may be delivered to must EXACTLY match one the client
  # registered — an unregistered or missing value has no trusted destination.
  defp trusted_redirect_uri(%Client{redirect_uris: redirect_uris}, redirect_uri)
       when is_binary(redirect_uri) do
    if redirect_uri in (redirect_uris || []),
      do: {:ok, redirect_uri},
      else: {:error, :invalid_redirect_uri}
  end

  defp trusted_redirect_uri(%Client{}, _redirect_uri), do: {:error, :invalid_redirect_uri}

  # The OAuth-shaped protocol checks, in the order the errors are reported.
  # MCP mandates S256, so `plain` (and any other named method) is refused; an
  # absent method means S256. `resource` is RFC 8707 audience binding: this AS
  # issues tokens for exactly one MCP endpoint.
  defp ensure_request_supported(params) do
    cond do
      params["response_type"] != "code" -> {:error, "unsupported_response_type"}
      not s256_code_challenge?(params["code_challenge"]) -> {:error, "invalid_request"}
      params["code_challenge_method"] not in [nil, "S256"] -> {:error, "invalid_request"}
      params["resource"] != PublicUrl.url("/api/mcp/rpc") -> {:error, "invalid_target"}
      true -> :ok
    end
  end

  # RFC 7636 §4.2 — an S256 challenge is the unpadded base64url encoding of a
  # 32-byte digest, so exactly 43 characters of that alphabet. Anything else is
  # a malformed or entropy-downgraded challenge, refused before it's stored.
  defp s256_code_challenge?(challenge) when is_binary(challenge),
    do: byte_size(challenge) == 43 and challenge =~ ~r/\A[A-Za-z0-9_-]+\z/

  defp s256_code_challenge?(_challenge), do: false

  defp list_param(params, key, default \\ []) do
    case params[key] do
      v when is_list(v) -> v
      v when is_binary(v) -> [v]
      _ -> default
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  # RFC 8707 canonical URIs lowercase scheme + host. Keep the rest exact so
  # a token for one path, query, or port can never authenticate another MCP
  # resource, while accepting clients that capitalize only scheme or host.
  defp resource_matches?(token_resource, expected_resource) do
    with {:ok, normalized_token} <- normalize_resource_uri(token_resource),
         {:ok, normalized_expected} <- normalize_resource_uri(expected_resource) do
      normalized_token == normalized_expected
    else
      _ -> false
    end
  end

  defp normalize_resource_uri(resource) when is_binary(resource) do
    case URI.parse(resource) do
      %URI{scheme: scheme, host: host, fragment: nil} = uri
      when is_binary(scheme) and is_binary(host) ->
        normalized = %URI{uri | scheme: String.downcase(scheme), host: String.downcase(host)}
        {:ok, URI.to_string(normalized)}

      _ ->
        :error
    end
  end

  defp normalize_resource_uri(_), do: :error

  defp live?(nil), do: false
  defp live?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) == :gt
  defp secs_from_now(s), do: DateTime.add(DateTime.utc_now(), s, :second)

  # `peek_api_key_by_id` returns nil unless the key passes `key_usable?/2`
  # (not revoked / deleted / expired) — the same liveness gate the access
  # token's resolve path uses.
  defp backing_key_usable?(api_key_id), do: not is_nil(ApiKeys.peek_api_key_by_id(api_key_id))

  # Every access token carries the `mcp` scope: that scope IS the capability to
  # reach the MCP resource, and this is the only writer of a token's scope.
  # `offline_access` is additive and only gates refresh-token issuance
  # (`mint_token_pair/1`), so a client that requests it — or requests nothing —
  # still gets `mcp`, and a raw, client-controlled scope string can't smuggle an
  # unsupported scope in.
  defp narrow_scope(raw) do
    requested = String.split(raw || "", ~r/\s+/, trim: true)
    if "offline_access" in requested, do: "mcp offline_access", else: "mcp"
  end

  # RFC 8707 — a token request MAY repeat the `resource` it wants the token
  # for. When present it must match the resource the grant was bound to at
  # consent (absent leaves that binding intact). A MISMATCH is a client asking
  # for a token aimed at a resource it was never authorized for → fail closed.
  defp resource_param_ok?(_bound, nil), do: true

  defp resource_param_ok?(bound, requested) when is_binary(requested),
    do: resource_matches?(bound, requested)

  defp resource_param_ok?(_bound, _requested), do: false
end
