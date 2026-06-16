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
  verification against the system CA store (the /deps-audit caveat — httpc does
  not verify by default, and a MITM on the JWKS/token endpoint would forge
  tokens).

  oidcc's `retrieve_token/5` validates the ID-token signature (JWKS), `iss`,
  `aud` (== our `client_id`, rejecting untrusted extra audiences), `exp`, and
  `nonce` automatically; the RFC 9207 authorization-response `iss` check (the
  mix-up defense) is done here.
  """
  @behaviour Emisar.SSO.OIDC

  alias Emisar.Crypto
  alias Emisar.SSO.IdentityProvider

  @registry Emisar.SSO.OIDC.Registry
  @supervisor Emisar.SSO.OIDC.ProviderSupervisor
  @default_scopes ["openid", "email", "profile"]

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
      require_pkce: true
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
      pkce_verifier: stashed.pkce_verifier
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
    case Map.get(token.id.claims, claim) do
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

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
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
