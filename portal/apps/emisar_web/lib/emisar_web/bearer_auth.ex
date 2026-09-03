defmodule EmisarWeb.BearerAuth do
  @moduledoc """
  The static-API-key half of HTTP bearer authentication, shared by the two
  key-authenticated surfaces (MCP RPC and the audit NDJSON feed): parse the
  `authorization` header, resolve a presented secret to its key + account, and
  build the standard request assigns from them.

  Deliberately NOT here: OAuth `emo-` resolution (MCP-only — an OAuth token is
  bound to the MCP resource and must not authenticate the audit feed), and
  which key KINDS a surface accepts (each surface's own gate).
  """

  import Plug.Conn, only: [assign: 3]
  alias Emisar.{Accounts, ApiKeys}
  alias Emisar.Auth.Subject
  alias EmisarWeb.RequestContext

  @doc """
  The bearer token in an `authorization` header list, or `:error`.

  RFC 9110 §11.1 makes the auth-scheme token case-insensitive, so `bearer` is
  the same credential as `Bearer`; both surfaces freeze at 1.0, and a
  spec-conformant client must not read as a wrong key. Exactly one header line
  — two is ambiguous and fails closed, as it does elsewhere on this boundary.
  """
  def credential([value]) when is_binary(value) do
    trimmed = String.trim(value)

    case String.split(trimmed, ~r/\s+/, parts: 2) do
      [scheme, token] when token != "" ->
        if String.downcase(scheme) == "bearer", do: {:ok, token}, else: :error

      _ ->
        :error
    end
  end

  def credential(_headers), do: :error

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
