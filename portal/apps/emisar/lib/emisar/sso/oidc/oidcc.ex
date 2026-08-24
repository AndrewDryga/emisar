defmodule Emisar.SSO.OIDC.Oidcc do
  @moduledoc """
  Real `oidcc`-backed implementation of the `Emisar.SSO.OIDC` seam (oidcc 3.7).

  **We fetch; oidcc parses.** There is no discovery worker. Each sign-in loads
  the discovery document, judges every endpoint it names, and only then loads the
  JWKS — so the request to a `jwks_uri` pointing at loopback, RFC-1918 or the
  cloud metadata service is never made. That ordering is the whole point: oidcc's
  worker chains `load_configuration` straight into `load_jwks` inside one startup
  continuation, so any check placed after it is answering a question the network
  already asked, and tearing the worker down afterwards un-sends nothing.

  The cost is two requests to the IdP on the login path instead of a cached
  document, and it is worth paying here: logins are infrequent, a rotated JWKS or
  a corrected issuer takes effect on the next attempt with no cache to
  invalidate, and there is no supervised process left refreshing a document an
  account no longer uses. `client_id` / `client_secret` are read fresh from the
  provider on every request, so those edits are immediate too.

  Outbound discovery/JWKS/token requests go over OTP `httpc` with TLS peer +
  hostname verification against the system CA store (the /security-deps-audit
  caveat — httpc does not verify by default, and a MITM on the JWKS or token
  endpoint would forge tokens).

  oidcc's `retrieve_token/5` validates the ID-token signature (JWKS), `iss`,
  `aud` (== our `client_id`, rejecting untrusted extra audiences), `exp`, and
  `nonce` automatically; the RFC 9207 authorization-response `iss` check (the
  mix-up defense) is done here.
  """
  @behaviour Emisar.SSO.OIDC

  alias Emisar.Crypto
  alias Emisar.SSO.{IdentityProvider, IssuerUrl}
  alias Emisar.SSO.OIDC.Guard

  @default_scopes ["openid", "email", "profile"]
  # We hold a client secret, not a signing key — restrict client authentication to
  # the secret-based methods so oidcc never tries the JWT methods an IdP may
  # advertise but we can't satisfy.
  #
  # POST first, and that order is load-bearing. A pushed authorization request
  # carries `client_id` in its body; `client_secret_basic` adds a Basic header on
  # top and leaves that body alone, so Okta sees two credential sources and
  # answers `401 Cannot supply multiple client credentials` — the login fails
  # before the browser ever reaches the IdP. `client_secret_post` puts both
  # values in the body, where oidcc's `ukeysort` collapses the duplicate
  # `client_id`, leaving exactly one. Every IdP that supports basic supports
  # post, so preferring it costs nothing elsewhere.
  @secret_auth_methods [:client_secret_post, :client_secret_basic]

  @impl Emisar.SSO.OIDC
  def begin_authorization(%IdentityProvider{} = provider, opts) do
    state = Crypto.oidc_state()
    nonce = Crypto.oidc_nonce()
    verifier = Crypto.pkce_verifier()

    url_opts = %{
      redirect_uri: Keyword.fetch!(opts, :redirect_uri),
      scopes: Keyword.get(opts, :scopes, @default_scopes),
      state: state,
      nonce: nonce,
      pkce_verifier: verifier,
      # Fixed caller-owned additions such as the administrator reset step-up's
      # prompt=login/max_age=0. Callers never forward browser parameters here.
      url_extension: Keyword.get(opts, :url_extension, []),
      require_pkce: true,
      # We authenticate with a client SECRET, not a signing key — so constrain
      # the client-auth method to the secret-based ones. oidcc otherwise prefers
      # private_key_jwt / client_secret_jwt when the IdP advertises them (Okta,
      # Keycloak, …), which we can't satisfy → the PAR/token request 401s.
      preferred_auth_methods: @secret_auth_methods,
      # PAR is an outbound POST from here, and without this it went out on the
      # DEFAULT httpc profile — past the guard AND without our TLS verification
      # options, which is httpc's unverified default. Configuring the profile only
      # for discovery and JWKS left the two requests that carry the client secret
      # and the code as the unguarded ones.
      request_opts: request_opts()
    }

    with {:ok, context} <- client_context(provider),
         {:ok, url} <- Oidcc.Authorization.create_redirect_url(context, url_opts) do
      {:ok,
       %{
         authorize_url: IO.iodata_to_binary(url),
         state: state,
         nonce: nonce,
         pkce_verifier: verifier
       }}
    end
  end

  @impl Emisar.SSO.OIDC
  def verify_callback(%IdentityProvider{} = provider, params, stashed) do
    token_opts = callback_token_options(provider, stashed)

    with :ok <- ensure_state_matches(params, stashed),
         :ok <- ensure_response_issuer(params, provider),
         {:ok, code} <- fetch_code(params),
         {:ok, context} <- client_context(provider),
         {:ok, token} <- Oidcc.Token.retrieve(code, context, token_opts),
         {:ok, identifier} <- extract_identifier(token, provider) do
      {:ok, %{identifier: identifier, claims: token.id.claims}}
    end
  end

  @doc "Internal — the callback's complete oidcc token-validation policy."
  def callback_token_options(%IdentityProvider{} = provider, stashed) do
    %{
      redirect_uri: stashed.redirect_uri,
      nonce: stashed.nonce,
      pkce_verifier: stashed.pkce_verifier,
      # oidcc otherwise accepts any additional audience when our client_id is
      # also present. Empty means no trusted audience beyond the client itself.
      trusted_audiences: [],
      # Same as begin: secret-based client auth only (see @secret_auth_methods).
      preferred_auth_methods: @secret_auth_methods,
      # The token exchange, for the same reason PAR needs it above.
      request_opts: request_opts(),
      # An IdP that rotates signing keys between our JWKS load and its ID token
      # leaves us holding a `kid` we have never seen. The worker used to refetch on
      # that; without one, a rotation would have failed every sign-in until the
      # next attempt happened to land after the rotation. Refetch from the SAME
      # jwks_uri this document already passed — and through the guard, like every
      # other request.
      refresh_jwks: refresh_jwks(provider)
    }
  end

  @impl Emisar.SSO.OIDC
  def discover(%IdentityProvider{issuer: issuer} = provider) do
    # One-shot discovery (no worker lifecycle) over the SAME TLS verification as
    # the login flow, so a passing test truly predicts a reachable IdP. Fetches
    # `<issuer>/.well-known/openid-configuration`; the issuer is SSRF-validated
    # upstream in the context.
    case Oidcc.ProviderConfiguration.load_configuration(issuer, configuration_opts(provider)) do
      {:ok, {config, _expiry}} ->
        with :ok <- ensure_endpoints_reachable(config) do
          {:ok,
           %{
             authorization_endpoint: present(config.authorization_endpoint),
             token_endpoint: present(config.token_endpoint),
             userinfo_endpoint: present(config.userinfo_endpoint),
             jwks_uri: present(config.jwks_uri)
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A trusted issuer is not the same claim as a trusted document. Validating the
  # issuer stopped short of the fetches that follow: an ordinary public HTTPS
  # issuer can return a discovery document pointing `jwks_uri` or
  # `token_endpoint` at loopback, RFC-1918 or the cloud metadata service, and the
  # worker will GET the JWKS and POST the token exchange to whatever it is
  # handed. Hold every discovered endpoint to the policy the issuer passed.
  defp ensure_endpoints_reachable(config) do
    # An endpoint may live where the ISSUER lives, or anywhere the issuer itself
    # would have been allowed to live. Same-host adds no reach: whoever vouched
    # for the issuer vouched for that host. What this refuses is a document that
    # sends us SOMEWHERE ELSE — the metadata service, loopback, an internal
    # RFC-1918 box — which is the actual SSRF, and which a perfectly ordinary
    # public issuer can do.
    origin = origin_of(config.issuer)

    # The PAR endpoint is a POST we make before the browser ever leaves, so it is
    # as much an SSRF sink as the token endpoint and belongs under the same
    # policy. Leaving it out meant a document could keep every other endpoint
    # honest and still have us post the authorization request internally.
    [
      config.authorization_endpoint,
      config.token_endpoint,
      config.userinfo_endpoint,
      config.jwks_uri,
      config.pushed_authorization_request_endpoint
    ]
    |> Enum.reduce_while(:ok, fn endpoint, :ok ->
      if endpoint_allowed?(endpoint, origin),
        do: {:cont, :ok},
        else: {:halt, {:error, :blocked_discovery_endpoint}}
    end)
  end

  defp endpoint_allowed?(endpoint, issuer_origin) do
    case origin_of(endpoint) do
      # Same ORIGIN is the same reach: whoever vouched for the issuer vouched for
      # that host over that scheme. Comparing hosts alone was not enough — it let
      # a document downgrade us to `http://<issuer-host>:9200/`, which is neither
      # the issuer nor anything `validate_endpoint` would have passed. The issuer
      # is forced to https upstream, so matching its scheme is https in practice.
      ^issuer_origin when is_tuple(issuer_origin) -> true
      _ -> IssuerUrl.validate_endpoint(endpoint) == :ok
    end
  end

  defp origin_of(nil), do: nil
  defp origin_of(:undefined), do: nil
  defp origin_of(value) when is_list(value), do: value |> IO.iodata_to_binary() |> origin_of()

  defp origin_of(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        # PORT is part of an origin. Comparing scheme and host alone still let a
        # document send us to `https://<issuer-host>:9200/` — a different service
        # on the same box, which is the reach this exists to deny.
        {scheme, String.downcase(host), port || URI.default_port(scheme)}

      _ ->
        nil
    end
  end

  defp origin_of(_value), do: nil

  # oidcc renders an absent optional endpoint as :undefined and present ones as
  # uri_string iodata — normalize to a binary or nil for the UI.
  defp present(:undefined), do: nil
  defp present(value), do: IO.iodata_to_binary(value)

  # State (CSRF) must match the stashed value, constant-time.
  defp ensure_state_matches(%{"state" => state}, %{state: expected})
       when is_binary(state) and is_binary(expected) do
    if Crypto.secure_compare(state, expected), do: :ok, else: {:error, :state_mismatch}
  end

  defp ensure_state_matches(_params, _stashed), do: {:error, :state_mismatch}

  # RFC 9207 mix-up defense (R2): when the IdP echoes `iss` in the response, it
  # MUST equal the provider's configured issuer. (oidcc validates the ID-token
  # `iss` claim; this guards the authorization response itself.)
  defp ensure_response_issuer(%{"iss" => iss}, %IdentityProvider{issuer: issuer})
       when is_binary(iss) do
    if iss == issuer, do: :ok, else: {:error, :issuer_mismatch}
  end

  defp ensure_response_issuer(_params, _provider), do: :ok

  defp fetch_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp fetch_code(_params), do: {:error, :missing_code}

  defp extract_identifier(token, %IdentityProvider{identifier_claim: claim}) do
    # `identifier_claim` is an Ecto.Enum (atom); ID-token claim keys are strings.
    case Map.get(token.id.claims, to_string(claim)) do
      identifier when is_binary(identifier) and identifier != "" -> {:ok, identifier}
      _ -> {:error, :missing_identifier_claim}
    end
  end

  defp client_secret(%IdentityProvider{client_secret: nil}), do: :unauthenticated
  defp client_secret(%IdentityProvider{client_secret: secret}), do: secret

  # The ONE place a provider becomes something oidcc can act with, and the only
  # place any of these requests are made. Order is the security property: the
  # document is judged between the two fetches, so a `jwks_uri` we would refuse
  # is refused before anything connects to it.
  defp client_context(%IdentityProvider{} = provider) do
    with {:ok, config} <- load_configuration(provider),
         :ok <- ensure_endpoints_reachable(config),
         {:ok, jwks} <- load_jwks(config, provider) do
      {:ok,
       Oidcc.ClientContext.from_manual(
         config,
         jwks,
         provider.client_id,
         client_secret(provider)
       )}
    end
  end

  # oidcc calls this with the JWKS it has and the unknown `kid`; the reply replaces
  # its key set for this verification only. A refetch that still lacks the kid is an
  # error, so a bogus kid cannot make us fetch repeatedly within one sign-in.
  defp refresh_jwks(%IdentityProvider{} = provider) do
    fn _jwks, _kid ->
      with {:ok, config} <- load_configuration(provider),
           :ok <- ensure_endpoints_reachable(config) do
        load_jwks(config, provider)
      end
    end
  end

  defp load_configuration(%IdentityProvider{issuer: issuer} = provider) do
    case Oidcc.ProviderConfiguration.load_configuration(issuer, configuration_opts(provider)) do
      {:ok, {config, _expiry}} -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only reached once every endpoint has passed, so the URI here is one we have
  # already decided we may talk to.
  defp load_jwks(config, %IdentityProvider{} = provider) do
    case Oidcc.ProviderConfiguration.load_jwks(config.jwks_uri, configuration_opts(provider)) do
      {:ok, {jwks, _expiry}} -> {:ok, jwks}
      {:error, reason} -> {:error, reason}
    end
  end

  # httpc TLS: verify the IdP's cert chain + hostname against the OS CA store.
  # Entra supports PKCE (S256) for the authorization-code flow and simply does not
  # say so in its discovery document — a long-standing Microsoft gap. oidcc reads
  # that silence literally and refuses to start the flow
  # (`:no_supported_code_challenge`), so SSO through Entra could not begin at all.
  # The override states what the provider actually does; it is scoped to the kind
  # because assuming it everywhere would let us send a challenge an IdP ignores
  # and quietly lose the protection we think we have.
  defp configuration_opts(%IdentityProvider{kind: :entra}) do
    %{
      request_opts: request_opts(),
      # BINARY key: `document_overrides` is merged into the raw decoded discovery
      # JSON before parsing, and oidcc looks every field up by
      # `atom_to_binary(Key)`. An atom key here is silently ignored, which is
      # exactly what happened the first time.
      quirks: %{document_overrides: %{<<"code_challenge_methods_supported">> => [<<"S256">>]}}
    }
  end

  defp configuration_opts(%IdentityProvider{}), do: %{request_opts: request_opts()}

  defp request_opts do
    %{
      # The guard's profile, not the default one. This is what puts every request
      # oidcc makes — and every redirect it follows — behind the SSRF policy.
      httpc_profile: Guard.profile(),
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }
  end
end
