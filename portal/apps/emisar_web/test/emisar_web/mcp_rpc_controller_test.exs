defmodule EmisarWeb.MCPRpcControllerTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{ApiKeys, Crypto, Repo}
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.MCPOperations.Operation
  alias EmisarWeb.MCP.SchemaRegistry

  setup do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    _membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, raw, key} = ApiKeys.create_key(%{name: "rpc", kind: :mcp}, subject)

    {:ok, account: account, user: user, subject: subject, raw: raw, key: key}
  end

  describe "authentication and strict ingress" do
    test "missing bearer returns a correlated JSON-RPC challenge", %{conn: conn} do
      response = rpc(conn, "initialize", %{}, "missing-bearer")
      body = json_response(response, 401)

      assert body == %{
               "jsonrpc" => "2.0",
               "id" => "missing-bearer",
               "error" => %{"code" => -32_001, "message" => "unauthorized"}
             }

      assert [challenge] = get_resp_header(response, "www-authenticate")
      assert challenge =~ "resource_metadata="
    end

    test "invalid and revoked bearers have the same unauthorized shape", %{
      conn: conn,
      raw: raw,
      key: key,
      subject: subject
    } do
      invalid =
        conn
        |> authorize("emk-" <> String.duplicate("x", 48))
        |> rpc("ping")
        |> json_response(401)

      assert invalid["error"]["code"] == -32_001

      assert {:ok, _revoked} = ApiKeys.revoke_api_key(key, subject)

      revoked =
        build_conn()
        |> authorize(raw)
        |> rpc("ping")
        |> json_response(401)

      assert revoked["error"]["code"] == -32_001
    end

    test "decoded duplicate keys are rejected before authentication", %{conn: conn} do
      raw =
        ~s({"jsonrpc":"2.0","id":"duplicate","method":"tools/call","params":{"name":"run_action","arguments":{"args":{"job_id":1,"job\u005fid":2}}}})

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", raw)
        |> json_response(400)

      assert body == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_700, "message" => "Parse error"}
             }
    end

    test "the raw request cap fails without trusting a prefixed id", %{conn: conn} do
      raw = String.duplicate(" ", 128 * 1024 + 1)

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", raw)
        |> json_response(413)

      assert body == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_600, "message" => "Request body too large"}
             }
    end

    test "malformed JSON is an uncorrelated parse error", %{conn: conn, raw: raw} do
      body =
        conn
        |> authorize(raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", "{not valid json")
        |> json_response(400)

      assert %{"id" => nil, "error" => %{"code" => -32_700}} = body
    end
  end

  describe "JSON-RPC envelope" do
    test "string, negative, and arbitrarily large integer ids round-trip", %{raw: raw} do
      for id <- ["007", -42, 9_007_199_254_740_993_123_456_789] do
        body =
          build_conn()
          |> authorize(raw)
          |> rpc("ping", %{}, id)
          |> json_response(200)

        assert body == %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
      end
    end

    test "invalid JSON-RPC id types fail with id null", %{raw: raw} do
      for id <- [nil, true, 1.5, [], %{"nested" => 1}] do
        payload = %{jsonrpc: "2.0", id: id, method: "ping", params: %{}}

        body =
          build_conn()
          |> authorize(raw)
          |> put_req_header("content-type", "application/json")
          |> post(~p"/api/mcp/rpc", Jason.encode!(payload))
          |> json_response(400)

        assert body == %{
                 "jsonrpc" => "2.0",
                 "id" => nil,
                 "error" => %{"code" => -32_600, "message" => "invalid request"}
               }
      end
    end

    test "an id too large to echo inside the response budget fails uncorrelated", %{raw: raw} do
      payload = %{
        jsonrpc: "2.0",
        id: String.duplicate("i", 4_097),
        method: "ping",
        params: %{}
      }

      response =
        build_conn()
        |> authorize(raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(payload))

      assert byte_size(response.resp_body) < 512 * 1_024

      assert json_response(response, 400) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_600, "message" => "invalid request"}
             }
    end

    test "missing method and non-object params fail cleanly", %{conn: conn, raw: raw} do
      missing_method =
        conn
        |> authorize(raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(%{jsonrpc: "2.0", id: 1}))
        |> json_response(400)

      assert missing_method["error"]["code"] == -32_600

      invalid_params =
        build_conn()
        |> authorize(raw)
        |> rpc("initialize", ["not", "an", "object"])
        |> json_response(200)

      assert invalid_params["error"] == %{
               "code" => -32_602,
               "message" => "params must be an object"
             }
    end

    test "unknown methods and malformed tool calls remain correlated", %{conn: conn, raw: raw} do
      unknown =
        conn
        |> authorize(raw)
        |> rpc("does/not/exist", %{}, "unknown")
        |> json_response(200)

      assert %{"id" => "unknown", "error" => %{"code" => -32_601}} = unknown

      malformed =
        build_conn()
        |> authorize(raw)
        |> rpc("tools/call", %{"arguments" => %{}}, "bad-call")
        |> json_response(200)

      assert %{"id" => "bad-call", "error" => %{"code" => -32_602}} = malformed
    end

    test "unknown fixed tools return an in-band structured error", %{conn: conn, raw: raw} do
      body =
        conn
        |> authorize(raw)
        |> rpc("tools/call", %{"name" => "linux.uptime", "arguments" => %{}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert get_in(body, ["result", "structuredContent", "error", "code"]) == "unknown_tool"
    end
  end

  describe "notifications" do
    test "every notification is silent and a mutation notification creates nothing", %{
      raw: raw
    } do
      payloads = [
        %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}},
        %{jsonrpc: "2.0", method: "unknown/notification", params: %{}},
        %{
          jsonrpc: "2.0",
          method: "tools/call",
          params: %{
            name: "create_runbook_draft",
            arguments: %{title: "Must not persist", steps: []}
          }
        }
      ]

      Enum.each(payloads, fn payload ->
        response =
          build_conn()
          |> authorize(raw)
          |> put_req_header("content-type", "application/json")
          |> post(~p"/api/mcp/rpc", Jason.encode!(payload))

        assert response.status == 202
        assert response.resp_body == ""
      end)

      refute Repo.exists?(Operation)
    end

    test "cancellation notifications are also bodyless", %{conn: conn, raw: raw} do
      payload = %{
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: %{requestId: "request-1", reason: "client stopped waiting"}
      }

      response =
        conn
        |> authorize(raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(payload))

      assert response.status == 202
      assert response.resp_body == ""
    end
  end

  describe "initialize and sessions" do
    test "negotiates supported protocol versions and fixed capabilities", %{raw: raw} do
      for version <- ~w(2025-11-25 2025-06-18 2024-11-05) do
        body =
          build_conn()
          |> authorize(raw)
          |> rpc("initialize", %{"protocolVersion" => version})
          |> json_response(200)

        assert body["result"]["protocolVersion"] == version
        assert body["result"]["serverInfo"]["name"] == "emisar"
        assert get_in(body, ["result", "capabilities", "tools", "listChanged"]) == false
      end
    end

    test "records only bounded known clientInfo fields", %{conn: conn, raw: raw, key: key} do
      body =
        conn
        |> authorize(raw)
        |> rpc("initialize", %{
          "clientInfo" => %{
            "name" => "Claude Code",
            "title" => "Claude",
            "version" => "1.2.3",
            "junk" => "drop"
          }
        })
        |> json_response(200)

      assert body["result"]["instructions"] =~ "get_operation"

      reloaded = Repo.get!(ApiKey, key.id)

      assert reloaded.last_client_info == %{
               "name" => "Claude Code",
               "title" => "Claude",
               "version" => "1.2.3"
             }
    end

    test "reuses valid session ids and replaces blank or oversized values", %{raw: raw} do
      fresh = build_conn() |> authorize(raw) |> rpc("initialize")
      assert [generated] = get_resp_header(fresh, "mcp-session-id")
      assert {:ok, _uuid} = Ecto.UUID.cast(generated)

      reused =
        build_conn()
        |> authorize(raw)
        |> put_req_header("mcp-session-id", "existing-session")
        |> rpc("initialize")

      assert get_resp_header(reused, "mcp-session-id") == ["existing-session"]

      for invalid <- ["", String.duplicate("s", 256)] do
        replaced =
          build_conn()
          |> authorize(raw)
          |> put_req_header("mcp-session-id", invalid)
          |> rpc("initialize")

        assert [minted] = get_resp_header(replaced, "mcp-session-id")
        assert {:ok, _uuid} = Ecto.UUID.cast(minted)
      end
    end

    test "omitted params default to an empty initialize object", %{conn: conn, raw: raw} do
      body =
        conn
        |> authorize(raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize"}))
        |> json_response(200)

      assert body["result"]["protocolVersion"] == "2025-11-25"
    end
  end

  describe "fixed tools" do
    test "tools/list returns exactly the schema-registry descriptors", %{conn: conn, raw: raw} do
      body = conn |> authorize(raw) |> rpc("tools/list") |> json_response(200)
      assert body["result"]["tools"] == SchemaRegistry.tools()
      assert length(body["result"]["tools"]) == 12
    end

    test "non-MCP keys are refused at the tool boundary", %{conn: conn, subject: subject} do
      {:ok, raw, _key} = ApiKeys.create_key(%{name: "audit", kind: :audit_export}, subject)
      body = conn |> authorize(raw) |> rpc("tools/list") |> json_response(200)

      assert body["error"]["code"] == -32_002
      assert body["error"]["data"]["required"] == "mcp"
    end
  end

  describe "bridge key rotation" do
    test "an ordinary authenticated request can acknowledge a pending successor", %{
      conn: conn,
      subject: subject
    } do
      expires_at = DateTime.add(DateTime.utc_now(), 3, :day)

      {:ok, raw, key} =
        ApiKeys.create_key(
          %{name: "long-lived bridge", kind: :mcp, expires_at: expires_at},
          subject
        )

      {_successor_raw, prefix, hash} = Crypto.mint("emk-", 12)

      response =
        conn
        |> authorize(raw)
        |> put_req_header("user-agent", "emisar-mcp/1.0.0 (client=test)")
        |> put_req_header("x-emisar-rotation-prefix", prefix)
        |> put_req_header("x-emisar-rotation-hash", Base.encode16(hash, case: :lower))
        |> rpc("ping")

      assert json_response(response, 200)["result"] == %{}

      assert get_resp_header(response, "x-emisar-rotation-ack") == [
               Base.encode16(hash, case: :lower)
             ]

      assert Repo.reload!(key).rotated_to_id
    end
  end

  describe "Streamable HTTP transport" do
    test "GET and DELETE never open or terminate a session", %{conn: conn} do
      get_response = get(conn, ~p"/api/mcp/rpc")
      assert json_response(get_response, 405)["error"] =~ "only accepts POST"
      assert get_resp_header(get_response, "allow") == ["POST"]

      delete_response = delete(build_conn(), ~p"/api/mcp/rpc")
      assert json_response(delete_response, 405)
    end

    test "cross-origin, content-type, and accept checks run before auth", %{conn: conn} do
      cross_origin =
        conn
        |> put_req_header("origin", "https://evil.example.com")
        |> rpc("initialize")
        |> json_response(403)

      assert cross_origin["error"]["message"] =~ "Cross-origin"

      wrong_type =
        build_conn()
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/mcp/rpc", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
        |> json_response(415)

      assert wrong_type["error"]["message"] =~ "application/json"

      wrong_accept =
        build_conn()
        |> put_req_header("accept", "text/event-stream")
        |> rpc("initialize")
        |> json_response(406)

      assert wrong_accept["error"]["message"] =~ "Accept"
    end

    test "same-origin JSON and the combined MCP accept header pass", %{raw: raw} do
      body =
        build_conn()
        |> authorize(raw)
        |> put_req_header("origin", EmisarWeb.Endpoint.url())
        |> put_req_header("accept", "application/json, text/event-stream")
        |> rpc("initialize")
        |> json_response(200)

      assert body["result"]["serverInfo"]["name"] == "emisar"
    end

    test "post-initialize protocol headers are checked but initialize negotiates in-body", %{
      raw: raw
    } do
      unsupported =
        build_conn()
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> rpc("ping")
        |> json_response(400)

      assert unsupported["error"]["message"] =~ "MCP-Protocol-Version"

      supported =
        build_conn()
        |> authorize(raw)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> rpc("ping")
        |> json_response(200)

      assert supported["result"] == %{}

      initialize =
        build_conn()
        |> authorize(raw)
        |> put_req_header("mcp-protocol-version", "not-a-version")
        |> rpc("initialize")
        |> json_response(200)

      assert initialize["result"]["serverInfo"]["name"] == "emisar"
    end
  end

  defp authorize(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    body = %{jsonrpc: "2.0", id: id, method: method, params: params}

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp/rpc", Jason.encode!(body))
  end
end
