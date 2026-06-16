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

  @callback begin_authorization(provider :: struct(), opts :: keyword()) ::
              {:ok, begin()} | {:error, term()}
  @callback verify_callback(provider :: struct(), params :: map(), stashed :: map()) ::
              {:ok, verified()} | {:error, term()}

  def begin_authorization(provider, opts), do: impl().begin_authorization(provider, opts)

  def verify_callback(provider, params, stashed),
    do: impl().verify_callback(provider, params, stashed)

  defp impl, do: Application.get_env(:emisar, :sso_oidc_impl, Emisar.SSO.OIDC.Oidcc)
end
