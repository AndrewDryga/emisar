defmodule Emisar.SSO.OIDC.Oidcc do
  @moduledoc """
  Real `oidcc`-backed implementation of the `Emisar.SSO.OIDC` seam (oidcc 3.7).

  A per-provider `Oidcc.ProviderConfiguration.Worker` (discovery doc + an
  auto-refreshing JWKS cache) is started lazily under
  `Emisar.SSO.OIDC.ProviderSupervisor`, named via `Emisar.SSO.OIDC.Registry`
  by `{provider id, issuer}`. Keying on the issuer means an operator's issuer
  edit transparently routes the next login — on any node — to a fresh worker
  for the new discovery/JWKS, with no stale cache to invalidate; the prior
  worker idles until the node restarts (issuer edits are rare). The `client_id`
  / `client_secret` are read fresh from the provider on each request, not baked
  into the worker, so those edits take effect immediately. Outbound
  discovery/JWKS/token requests go over OTP `httpc` with TLS peer + hostname
  verification against the system CA store (the /security-deps-audit caveat — httpc does
  not verify by default, and a MITM on the JWKS/token endpoint would forge
  tokens).

  oidcc's `retrieve_token/5` validates the ID-token signature (JWKS), `iss`,
  `aud` (== our `client_id`, rejecting untrusted extra audiences), `exp`, and
  `nonce` automatically; the RFC 9207 authorization-response `iss` check (the
  mix-up defense) is done here.
  """
  @behaviour Emisar.SSO.OIDC

  alias Emisar.Crypto
  alias Emisar.SSO.{IdentityProvider, IssuerUrl}

  @registry Emisar.SSO.OIDC.Registry
  @supervisor Emisar.SSO.OIDC.ProviderSupervisor
  @default_scopes ["openid", "email", "profile"]
  # We hold a client secret, not a signing key — restrict client authentication
  # to the secret-based methods (basic, then post) so oidcc never tries the JWT
  # methods an IdP may advertise but we can't satisfy.
  @secret_auth_methods [:client_secret_basic, :client_secret_post]

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
      require_pkce: true,
      # We authenticate with a client SECRET, not a signing key — so constrain
      # the client-auth method to the secret-based ones. oidcc otherwise prefers
      # private_key_jwt / client_secret_jwt when the IdP advertises them (Okta,
      # Keycloak, …), which we can't satisfy → the PAR/token request 401s.
      preferred_auth_methods: @secret_auth_methods
    }

    with {:ok, worker} <- ensure_worker(provider),
         {:ok, url} <-
           Oidcc.create_redirect_url(
             worker,
             provider.client_id,
             client_secret(provider),
             url_opts
           ) do
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
    token_opts = %{
      redirect_uri: stashed.redirect_uri,
      nonce: stashed.nonce,
      pkce_verifier: stashed.pkce_verifier,
      # Same as begin: secret-based client auth only (see @secret_auth_methods).
      preferred_auth_methods: @secret_auth_methods
    }

    with :ok <- ensure_state_matches(params, stashed),
         :ok <- ensure_response_issuer(params, provider),
         {:ok, code} <- fetch_code(params),
         {:ok, worker} <- ensure_worker(provider),
         {:ok, token} <-
           Oidcc.retrieve_token(
             code,
             worker,
             provider.client_id,
             client_secret(provider),
             token_opts
           ),
         {:ok, identifier} <- extract_identifier(token, provider) do
      {:ok, %{identifier: identifier, claims: token.id.claims}}
    end
  end

  @impl Emisar.SSO.OIDC
  def discover(%IdentityProvider{issuer: issuer}) do
    # One-shot discovery (no worker lifecycle) over the SAME TLS verification as
    # the login flow, so a passing test truly predicts a reachable IdP. Fetches
    # `<issuer>/.well-known/openid-configuration`; the issuer is SSRF-validated
    # upstream in the context.
    case Oidcc.ProviderConfiguration.load_configuration(issuer, %{request_opts: request_opts()}) do
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
    issuer_host = host_of(config.issuer)

    [
      config.authorization_endpoint,
      config.token_endpoint,
      config.userinfo_endpoint,
      config.jwks_uri
    ]
    |> Enum.reduce_while(:ok, fn endpoint, :ok ->
      if endpoint_allowed?(endpoint, issuer_host),
        do: {:cont, :ok},
        else: {:halt, {:error, :blocked_discovery_endpoint}}
    end)
  end

  defp endpoint_allowed?(endpoint, issuer_host) do
    case host_of(endpoint) do
      ^issuer_host when is_binary(issuer_host) -> true
      _ -> IssuerUrl.validate_endpoint(endpoint) == :ok
    end
  end

  defp host_of(nil), do: nil
  defp host_of(:undefined), do: nil
  defp host_of(value) when is_list(value), do: value |> IO.iodata_to_binary() |> host_of()

  defp host_of(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp host_of(_value), do: nil

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

  defp ensure_worker(%IdentityProvider{id: id, issuer: issuer}) do
    # Keyed by {id, issuer}: an issuer edit routes to a fresh worker (the old
    # one idles out) instead of serving stale discovery/JWKS — cluster-safe,
    # no cross-node invalidation needed.
    name = {:via, Registry, {@registry, {id, issuer}}}

    worker_opts = %{
      issuer: issuer,
      name: name,
      provider_configuration_opts: %{request_opts: request_opts()}
    }

    spec = %{
      id: {:oidc_provider, id},
      start: {Oidcc.ProviderConfiguration.Worker, :start_link, [worker_opts]},
      restart: :transient
    }

    # Hand oidcc the worker PID, not the `{:via, Registry, …}` name: oidcc's
    # `from_configuration_worker/4` resolves a non-pid via `:erlang.whereis/1`,
    # which only accepts an atom and raises on a via-tuple. The Registry name
    # still drives the keyed-by-{id,issuer} `:already_started` resolution above;
    # we just pass the live pid it returns to `create_redirect_url`/`retrieve_token`.
    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> ensure_worker_endpoints_reachable(pid)
      {:error, {:already_started, pid}} -> ensure_worker_endpoints_reachable(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  # The worker fetches discovery itself, so validating only the "Test connection"
  # capstone would leave every real sign-in unguarded — the login path never goes
  # through discover/1. Check what the worker actually loaded, and take it down
  # rather than leave a supervised process happily refreshing a document that
  # points at internal infrastructure.
  defp ensure_worker_endpoints_reachable(pid) do
    config = Oidcc.ProviderConfiguration.Worker.get_provider_configuration(pid)

    case ensure_endpoints_reachable(config) do
      :ok ->
        {:ok, pid}

      {:error, reason} ->
        _ = DynamicSupervisor.terminate_child(@supervisor, pid)
        {:error, reason}
    end
  end

  # httpc TLS: verify the IdP's cert chain + hostname against the OS CA store.
  defp request_opts do
    %{
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
