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
  alias Emisar.SSO
  alias EmisarWeb.SCIM.Resource

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {:ok, provider} <- SSO.authenticate_scim_token(raw) do
      assign(conn, :scim_provider, provider)
    else
      _ -> unauthorized(conn)
    end
  end

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
