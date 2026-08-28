defmodule EmisarWeb.BearerAuth do
  @moduledoc """
  The static-API-key half of HTTP bearer authentication, shared by the two
  key-authenticated surfaces (MCP RPC and the audit NDJSON feed): resolve a
  presented secret to its key + account, and build the standard request
  assigns from them.

  Deliberately NOT here: header parsing (the MCP surface branches on token
  shape first), OAuth `emo-` resolution (MCP-only — an OAuth token is bound
  to the MCP resource and must not authenticate the audit feed), and which
  key KINDS a surface accepts (each surface's own gate).
  """

  import Plug.Conn, only: [assign: 3]
  alias Emisar.{Accounts, ApiKeys}
  alias Emisar.Auth.Subject
  alias EmisarWeb.RequestContext

  @doc "Resolves a raw static key secret to `{:ok, key, account}`, or `:error`."
  def resolve_static_key(raw) when is_binary(raw) do
    with %{} = key <- ApiKeys.peek_api_key_by_secret(raw),
         {:ok, account} <- Accounts.fetch_account_by_id(key.account_id) do
      {:ok, key, account}
    else
      _ -> :error
    end
  end

  @doc "Assigns `:api_key` and the key's `:current_subject` onto the conn."
  def assign_api_key(conn, key, account) do
    conn
    |> assign(:api_key, key)
    |> assign(:current_subject, Subject.for_api_key(key, account, RequestContext.from_conn(conn)))
  end
end
