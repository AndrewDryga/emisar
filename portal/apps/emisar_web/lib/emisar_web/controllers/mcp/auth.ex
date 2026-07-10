defmodule EmisarWeb.MCP.Auth do
  @moduledoc """
  Shared bearer authentication for the MCP HTTP surfaces — the JSON-RPC
  `/api/mcp/rpc` endpoint and the REST `/api/mcp/*` routes. Resolves a
  presented bearer (a static `emk-` API key OR an `emo-` OAuth access
  token; both resolve to `api_keys` rows, so downstream scoping +
  attribution is identical) and, on failure, emits RFC 9728's
  `WWW-Authenticate` challenge so a remote MCP client can discover the
  authorization server and start the OAuth flow.
  """
  import Plug.Conn
  alias Emisar.{Accounts, ApiKeys, OAuth}
  alias Emisar.Auth.Subject
  alias EmisarWeb.RequestContext

  @doc """
  Resolves the request's bearer. On success assigns `:api_key` +
  `:current_subject` and returns `{:ok, conn}`. On failure sets the
  `WWW-Authenticate` header and returns `{:error, conn}` — the caller
  renders its own unauthorized body (the JSON-RPC and REST surfaces
  shape the 401 differently).
  """
  def authenticate(conn) do
    case resolve_bearer(conn) do
      {:ok, key, account} ->
        {:ok,
         conn
         |> assign(:api_key, key)
         |> assign(
           :current_subject,
           Subject.for_api_key(key, account, RequestContext.from_conn(conn))
         )}

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

  defp resolve_token(raw) do
    with %{} = key <- ApiKeys.peek_api_key_by_secret(raw),
         {:ok, account} <- Accounts.fetch_account_by_id(key.account_id) do
      {:ok, key, account}
    else
      _ -> :error
    end
  end

  # RFC 9728 §5.1 — point unauthenticated clients at the protected-resource
  # metadata and advertise `scope="mcp"`, the single scope every MCP access
  # token must carry. The configured endpoint URL stays stable rather than
  # echoing whichever Host header the request arrived with.
  defp challenge do
    ~s(Bearer resource_metadata="#{EmisarWeb.Endpoint.url()}/.well-known/oauth-protected-resource", scope="mcp")
  end
end
