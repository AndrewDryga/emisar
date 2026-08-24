defmodule Emisar.SSO.OIDC do
  @moduledoc """
  Relying-party OIDC flow, wrapping `oidcc` behind a project seam (IL-19).

  Two steps:

    * `begin_authorization/2` — build the IdP authorization redirect (auth-code
      + PKCE S256 + state + nonce), returning the URL plus the transaction
      secrets (`state`/`nonce`/`pkce_verifier`) the web layer stashes in the
      encrypted browser session. The callback response clears that stash; the
      provider and account budgets bound replay of a copied pre-response
      cookie.
    * `verify_callback/3` — exchange the code and validate the ID token
      (signature via JWKS, `iss` exact-match, `aud` == our `client_id` with no
      untrusted extra audiences, `exp`, `nonce`), plus the RFC 9207 issuer
      check (mix-up defense, R2), returning the stable `identifier` (the
      provider's `identifier_claim`) and the claims map.

  The implementation is swappable via `config :emisar, :sso_oidc_impl` so tests
  drive the resolution/JIT logic with a stub IdP and no network round-trip; the
  default is `Emisar.SSO.OIDC.Oidcc`.
  """

  @typedoc "What the web layer stashes in its encrypted session between begin and callback."
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

  # One fixed window is shared by authorization, callback, and unsaved discovery
  # work. A complete login spends two entries; a replayed callback or an
  # authenticated reset goes through both the canonical provider budget and its
  # account's aggregate budget. Test-connection discovery spends that same
  # account budget, so rotating providers or entry points cannot fill the Guard
  # pool. Persistent httpc sessions are disabled, so the adjacent-window account
  # burst still leaves headroom in that pool.
  @provider_work_limit 20
  @provider_work_window_ms 60_000
  @account_work_limit 20
  @account_work_window_ms 60_000

  def begin_authorization(provider, opts) do
    with :ok <- throttle_provider_work(provider),
         :ok <- throttle_account_work(provider) do
      impl().begin_authorization(provider, opts)
    end
  end

  def verify_callback(provider, params, stashed) do
    with :ok <- throttle_provider_work(provider),
         :ok <- throttle_account_work(provider) do
      impl().verify_callback(provider, params, stashed)
    end
  end

  @doc "Probe an issuer's OIDC discovery document — used by `SSO.test_provider/2`, no row written."
  def discover(provider) do
    with :ok <- throttle_account_work(provider) do
      impl().discover(provider)
    end
  end

  defp throttle_provider_work(%{id: provider_id}) when is_binary(provider_id) do
    Emisar.Throttle.check(
      "sso_oidc_provider_work",
      provider_id,
      @provider_work_limit,
      @provider_work_window_ms
    )
  end

  defp throttle_provider_work(_provider), do: {:error, :provider_not_ready}

  defp throttle_account_work(%{account_id: account_id}) when is_binary(account_id) do
    Emisar.Throttle.check(
      "sso_oidc_account_work",
      account_id,
      @account_work_limit,
      @account_work_window_ms
    )
  end

  defp throttle_account_work(_provider), do: {:error, :provider_not_ready}

  defp impl, do: Emisar.Config.get_env(:emisar, :sso_oidc_impl, Emisar.SSO.OIDC.Oidcc)
end
