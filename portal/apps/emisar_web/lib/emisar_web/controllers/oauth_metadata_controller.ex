defmodule EmisarWeb.OAuthMetadataController do
  @moduledoc """
  OAuth discovery metadata the MCP authorization spec requires:

    * `/.well-known/oauth-protected-resource` (RFC 9728) — tells the
      client which authorization server protects the MCP endpoint.
    * `/.well-known/oauth-authorization-server` (RFC 8414) — the AS
      endpoints + capabilities (PKCE S256, DCR, refresh).

  URLs are derived from the request host so the documents are
  self-consistent whichever host the client connected through
  (emisar.dev / app.emisar.dev / localhost).
  """
  use EmisarWeb, :controller

  alias Emisar.OAuth

  # RFC 9728 — protected resource metadata. `resource` is the canonical
  # MCP endpoint URI clients bind tokens to (RFC 8707).
  def protected_resource(conn, _params) do
    base = EmisarWeb.Endpoint.url()

    json(conn, %{
      resource: base <> "/api/mcp/rpc",
      authorization_servers: [base],
      scopes_supported: OAuth.supported_scopes(),
      bearer_methods_supported: ["header"]
    })
  end

  # RFC 8414 — authorization server metadata.
  def authorization_server(conn, _params) do
    base = EmisarWeb.Endpoint.url()

    json(conn, %{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: OAuth.supported_scopes()
    })
  end
end
