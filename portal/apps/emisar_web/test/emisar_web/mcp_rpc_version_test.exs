defmodule EmisarWeb.MCPRpcVersionTest do
  # async: false — these tests flip the global Emisar.Compat MCP enforcement
  # flag (VM-wide). Kept out of the main mcp_rpc_controller_test so that suite
  # stays async.
  use EmisarWeb.ConnCase, async: false
  alias Emisar.{ApiKeys, Fixtures}

  # test.exs policy: < 0.0.1 unsupported, [0.0.1, 0.1.0) outdated, >= 0.1.0 supported.
  describe "initialize — emisar-mcp bridge version enforcement" do
    setup :mcp_key

    test "enforce on: an unsupported bridge version is refused with a structured -32003",
         %{conn: conn, raw: raw} do
      enforce_mcp_versions(true)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("user-agent", "emisar-mcp/0.0.0 (client=test)")
        |> rpc("initialize")
        |> json_response(200)

      assert body["error"]["code"] == -32003
      assert body["error"]["data"]["minimum"] == ">= 0.0.1"
      assert body["error"]["data"]["your_version"] == "0.0.0"
      assert body["error"]["data"]["upgrade"] =~ "emisar-mcp"
      refute body["result"]
    end

    test "warn-only (enforcement off): an unsupported bridge version still handshakes",
         %{conn: conn, raw: raw} do
      # Baseline test config already has mcp_enforce: false.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("user-agent", "emisar-mcp/0.0.0 (client=test)")
        |> rpc("initialize")
        |> json_response(200)

      assert body["result"]["serverInfo"]["name"] == "emisar"
      refute body["error"]
    end

    test "enforce on: a current bridge version handshakes normally", %{conn: conn, raw: raw} do
      enforce_mcp_versions(true)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("user-agent", "emisar-mcp/1.0.0 (client=test)")
        |> rpc("initialize")
        |> json_response(200)

      assert body["result"]["serverInfo"]["name"] == "emisar"
      refute body["error"]
    end

    test "enforce on: a remote connector with no bridge UA is never blocked (:unknown)",
         %{conn: conn, raw: raw} do
      enforce_mcp_versions(true)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("initialize")
        |> json_response(200)

      assert body["result"]["serverInfo"]["name"] == "emisar"
      refute body["error"]
    end
  end

  defp mcp_key(_ctx) do
    {:ok, user} =
      Emisar.Users.register_user(%{
        email: "owner-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, account} =
      Emisar.Accounts.create_account_with_owner(
        %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo")},
        user
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, raw, _key} = ApiKeys.create_key(%{name: "mcp-key", kind: :mcp}, subject)
    %{raw: raw}
  end

  defp enforce_mcp_versions(enforce?) do
    previous = Emisar.Config.get_env(:emisar, Emisar.Compat)

    Emisar.Config.put_override(
      :emisar,
      Emisar.Compat,
      Keyword.put(previous, :mcp_enforce, enforce?)
    )
  end

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    body = %{jsonrpc: "2.0", id: id, method: method, params: params}

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp/rpc", Jason.encode!(body))
  end
end
