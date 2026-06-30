defmodule Emisar.SSO.OIDC do
  @moduledoc """
  Relying-party OIDC flow, wrapping `oidcc` behind a project seam (IL-19).

  Two steps:

    * `begin_authorization/2` — build the IdP authorization redirect (auth-code
      + PKCE S256 + state + nonce), returning the URL plus the transaction
      secrets (`state`/`nonce`/`pkce_verifier`) the web layer stashes,
      one-time-use and bound to the user agent (R3).
    * `verify_callback/3` — exchange the code and validate the ID token
      (signature via JWKS, `iss` exact-match, `aud` == our `client_id` with no
      untrusted extra audiences, `exp`, `nonce`), plus the RFC 9207 issuer
      check (mix-up defense, R2), returning the stable `identifier` (the
      provider's `identifier_claim`) and the claims map.

  The implementation is swappable via `config :emisar, :sso_oidc_impl` so tests
  drive the resolution/JIT logic with a stub IdP and no network round-trip; the
  default is `Emisar.SSO.OIDC.Oidcc`.
  """

  @typedoc "What the web layer must stash (UA-bound, one-time-use) between begin + callback."
  @type begin :: %{
          authorize_url: String.t(),
          state: String.t(),
          nonce: String.t(),
          pkce_verifier: String.t()
        }

  @typedoc "The validated outcome: the stable identifier (the `identifier_claim`) + the claims."
  @type verified :: %{identifier: String.t(), claims: map()}

  @typedoc "A discovery probe's result — the endpoints the IdP advertises (nil if absent)."
  @type discovery :: %{
          authorization_endpoint: String.t() | nil,
          token_endpoint: String.t() | nil,
          userinfo_endpoint: String.t() | nil,
          jwks_uri: String.t() | nil
        }

  @callback begin_authorization(provider :: struct(), opts :: keyword()) ::
              {:ok, begin()} | {:error, term()}
  @callback verify_callback(provider :: struct(), params :: map(), stashed :: map()) ::
              {:ok, verified()} | {:error, term()}
  @callback discover(provider :: struct()) :: {:ok, discovery()} | {:error, term()}

  # Only the "Test connection" capstone calls discover/1; the real impl + that
  # one test stub implement it, so the other (login-flow) test stubs needn't.
  @optional_callbacks discover: 1

  def begin_authorization(provider, opts), do: impl().begin_authorization(provider, opts)

  def verify_callback(provider, params, stashed),
    do: impl().verify_callback(provider, params, stashed)

  @doc "Probe an issuer's OIDC discovery document — used by `SSO.test_provider/2`, no row written."
  def discover(provider), do: impl().discover(provider)

  defp impl, do: Application.get_env(:emisar, :sso_oidc_impl, Emisar.SSO.OIDC.Oidcc)
end
