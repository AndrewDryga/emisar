defmodule EmisarWeb.SCIM.Auth do
  @moduledoc """
  Bearer authentication for the inbound SCIM 2.0 surface under `/scim/v2`.
  Resolves a presented `ems-` token to its `%Emisar.SSO.IdentityProvider{}`
  (the token is 1:1 with a provider — SCIM is one connection per IdP) and
  assigns it as `:scim_provider`; the controllers then drive the
  account-scoped `Emisar.SSO.scim_*` functions with it. The provider-scope
  IS the authorization — an account-A token can only ever touch account A.

  On any failure (missing, malformed, or unknown/disabled bearer) it halts
  with HTTP 401, the SCIM error body, and a `WWW-Authenticate: Bearer`
  challenge. Mirrors `EmisarWeb.Mcp.Auth`, but the SCIM surface shapes its
  own 401 (a SCIM Error resource), so this plug renders it directly.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  alias Emisar.{Crypto, SSO}
  alias EmisarWeb.SCIM.Resource

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw} <- bearer_token(get_req_header(conn, "authorization")),
         {:ok, provider} <- SSO.authenticate_scim_token(raw) do
      assign(conn, :scim_provider, provider)
    else
      _ -> unauthorized(conn)
    end
  end

  # Tolerant credential parse. The scheme keyword is case-insensitive (RFC 7235
  # §2.1 — `bearer` == `Bearer`) and IdP connectors / copy-paste routinely add
  # surrounding whitespace, so we accept either case, collapse the scheme/token
  # separator, and trim the token. We ALSO accept a schemeless raw token (see
  # the one-element clause). Throughout, the constant-time hash compare in
  # `SSO.authenticate_scim_token/1` stays the sole authenticator — this only
  # normalizes the envelope.
  defp bearer_token([value]) when is_binary(value) do
    trimmed = String.trim(value)

    case String.split(trimmed, ~r/\s+/, parts: 2) do
      [scheme, token] when token != "" ->
        if String.downcase(scheme) == "bearer", do: {:ok, token}, else: :error

      # Some IdP SCIM connectors (e.g. Okta's "SCIM 2.0 Test App (Header Auth)")
      # send the token as the raw Authorization value with NO `Bearer` scheme.
      # Accept it only when it carries our unambiguous `ems-` namespace — the
      # hash compare still authenticates, so this can't be confused with another
      # auth scheme.
      [token] ->
        if String.starts_with?(token, Crypto.scim_token_namespace()) do
          {:ok, token}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp bearer_token(_headers), do: :error

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(:unauthorized)
    |> json(
      Resource.error(401, "The SCIM bearer token is missing, malformed, or not authorized.")
    )
    |> halt()
  end
end
