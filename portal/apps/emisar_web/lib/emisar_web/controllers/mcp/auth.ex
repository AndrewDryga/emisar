defmodule EmisarWeb.MCP.Auth do
  @moduledoc """
  Bearer authentication for the MCP Streamable HTTP endpoint. Resolves a
  presented bearer (a static `emk-` API key OR an `emo-` OAuth access
  token; both resolve to `api_keys` rows, so downstream scoping +
  attribution is identical) and, on failure, emits RFC 9728's
  `WWW-Authenticate` challenge so a remote MCP client can discover the
  authorization server and start the OAuth flow.
  """
  import Plug.Conn
  alias Emisar.OAuth
  alias EmisarWeb.BearerAuth

  @doc """
  Resolves the request's bearer. On success assigns `:api_key` +
  `:current_subject` and returns `{:ok, conn}`. On failure sets the
  `WWW-Authenticate` header and returns `{:error, conn}` so the JSON-RPC
  boundary can render the correlated error.
  """
  def authenticate(conn) do
    case resolve_bearer(conn) do
      {:ok, key, account} ->
        {:ok, BearerAuth.assign_api_key(conn, key, account)}

      :error ->
        {:error, put_resp_header(conn, "www-authenticate", challenge())}
    end
  end

  @doc "Canonical URI this MCP HTTP surface accepts OAuth tokens for."
  def resource, do: EmisarWeb.Endpoint.url() <> "/api/mcp/rpc"

  defp resolve_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> resolve_token(raw)
      _ -> :error
    end
  end

  defp resolve_token("emo-" <> _ = raw) do
    case OAuth.resolve_access_token(raw, resource()) do
      {:ok, %{api_key: key, account: account}} -> {:ok, key, account}
      _ -> :error
    end
  end

  defp resolve_token(raw), do: BearerAuth.resolve_static_key(raw)

  # RFC 9728 §5.1 — point unauthenticated clients at the protected-resource
  # metadata and advertise `scope="mcp"`, the single scope every MCP access
  # token must carry. The configured endpoint URL stays stable rather than
  # echoing whichever Host header the request arrived with.
  defp challenge do
    ~s(Bearer resource_metadata="#{EmisarWeb.Endpoint.url()}/.well-known/oauth-protected-resource", scope="mcp")
  end
end
