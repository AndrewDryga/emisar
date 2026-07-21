defmodule EmisarWeb.MCPRpcControllerTest do
  use EmisarWeb.ConnCase, async: false
  import EmisarWeb.MCPContractAssertions
  import ExUnit.CaptureLog
  alias Emisar.{Accounts, ApiKeys, Crypto, Repo}
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

    test "a disabled account's static key is unauthorized without usage side effects", %{
      account: account,
      key: key,
      raw: raw,
      subject: subject
    } do
      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "support incident",
                 subject
               )

      body =
        build_conn()
        |> authorize(raw)
        |> rpc("ping")
        |> json_response(401)

      assert body["error"] == %{"code" => -32_001, "message" => "unauthorized"}
      assert is_nil(Repo.reload(key).last_used_at)
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

      assert get_in(body, ["result", "structuredContent", "error", "message"]) ==
               "Unknown tool. Emisar exposes only its twelve fixed API tools; an action id like 'postgres.restart' is not a tool. Discover with find_actions/get_action, then dispatch via run_action."
    end

    test "unknown tool telemetry correlates calls without logging their contents", %{raw: raw} do
      :ok = Logger.put_application_level(:emisar_web, :info)
      on_exit(fn -> Logger.delete_application_level(:emisar_web) end)

      tool = "sentinel.unknown_tool"
      secret = "sentinel_DO_NOT_LOG_call_value"

      log =
        capture_log([level: :info], fn ->
          for arguments <- [
                %{"value" => secret, "nested" => %{"n" => 1}},
                %{"nested" => %{"n" => 1}, "value" => secret},
                %{"value" => secret, "nested" => %{"n" => 2}}
              ] do
            body =
              build_conn()
              |> authorize(raw)
              |> rpc("tools/call", %{"name" => tool, "arguments" => arguments})
              |> json_response(200)

            assert get_in(body, ["result", "structuredContent", "error", "code"]) ==
                     "unknown_tool"
          end
        end)

      fingerprints =
        Regex.scan(~r/mcp_call_fingerprint=([0-9a-f]{64})/, log, capture: :all_but_first)
        |> List.flatten()

      assert [first, second, different] = fingerprints
      assert first == second
      refute first == different
      assert length(String.split(log, "mcp.unknown_tool")) == 4
      assert log =~ "mcp_tool=unknown"
      assert log =~ "mcp_unknown_tool_shape=action_id"
      refute log =~ tool
      refute log =~ secret
      refute log =~ raw
    end

    test "all twelve tools return the exact validation details contract", %{raw: raw} do
      Enum.each(SchemaRegistry.tool_names(), fn tool ->
        body =
          build_conn()
          |> authorize(raw)
          |> rpc("tools/call", %{
            "name" => tool,
            "arguments" => %{"unexpected" => "not accepted"}
          })
          |> json_response(200)

        result = get_in(body, ["result", "structuredContent"])
        assert_valid_tool_result(tool, result)
        assert result["error"]["code"] == "invalid_args", tool
        details = result["error"]["details"]
        assert details["schema_version"] == 1, tool
        assert details["stage"] in ~w(tool_call arguments action_arguments), tool
        assert is_binary(details["kind"]), tool
        assert [_first_issue | _rest] = details["issues"]
      end)
    end

    test "published input schemas reject non-objects and scalar string coercion", %{raw: raw} do
      cases = [
        {"list_packs", false, "$", "type"},
        {"list_runners", %{"limit" => "50"}, "$.limit", "type"},
        {"list_runners", %{"issues_only" => "true"}, "$.issues_only", "type"}
      ]

      for {tool, arguments, path, code} <- cases do
        body =
          build_conn()
          |> authorize(raw)
          |> rpc("tools/call", %{"name" => tool, "arguments" => arguments})
          |> json_response(200)

        result = get_in(body, ["result", "structuredContent"])
        assert_valid_tool_result(tool, result)
        assert result["error"]["code"] == "invalid_args"
        assert result["error"]["details"]["kind"] == "type"

        assert %{"path" => path, "code" => code} in result["error"]["details"]["issues"]
      end
    end

    test "validation details preserve semantic failure kinds and field paths", %{raw: raw} do
      cases = [
        {"list_runners", %{"limit" => "many"}, "type", "$.limit", "type"},
        {"run_action",
         %{
           "action_id" => 7,
           "pack_ref" => "linux@1.0.0/sha256:" <> String.duplicate("a", 64),
           "runner_refs" => ["node~" <> String.duplicate("a", 32)],
           "args" => %{},
           "reason" => "Inspect uptime"
         }, "type", "$.action_id", "type"},
        {"run_action",
         %{
           "action_id" => "linux.uptime",
           "pack_ref" => "linux@1.0.0/sha256:" <> String.duplicate("a", 64),
           "runner_refs" => ["not-a-runner-ref"],
           "args" => %{},
           "reason" => "Inspect uptime"
         }, "format", "$.runner_refs", "format"},
        {"run_action",
         %{
           "action_id" => "linux.uptime",
           "pack_ref" => "linux@1.0.0/sha256:" <> String.duplicate("a", 64),
           "runner_refs" => [7],
           "args" => %{},
           "reason" => "Inspect uptime"
         }, "type", "$.runner_refs", "type"},
        {"get_operation", %{"operation_id" => 7}, "type", "$.operation_id", "type"},
        {"wait_for_run",
         %{
           "run_id" => Ecto.UUID.generate(),
           "runbook_execution_id" => Ecto.UUID.generate()
         }, "conflict", "$", "conflict"},
        {"list_runbooks", %{"cursor" => 7}, "type", "$.cursor", "type"},
        {"create_runbook_draft",
         %{
           "title" => 7,
           "steps" => [
             %{
               "step_id" => "inspect",
               "action_id" => "linux.uptime",
               "pack_ref" => "linux@1.0.0/sha256:" <> String.duplicate("a", 64),
               "args" => %{},
               "runner_selector" => %{"groups" => ["prod"]}
             }
           ]
         }, "type", "$.title", "type"},
        {"execute_runbook", %{"runbook_ref" => "diagnose@1", "reason" => 7}, "type", "$.reason",
         "type"},
        {"recent_runs", %{"scope" => "global"}, "enum", "$.scope", "enum"}
      ]

      Enum.each(cases, fn {tool, arguments, kind, path, code} ->
        body =
          build_conn()
          |> authorize(raw)
          |> rpc("tools/call", %{"name" => tool, "arguments" => arguments})
          |> json_response(200)

        result = get_in(body, ["result", "structuredContent"])
        assert_valid_tool_result(tool, result)
        assert result["error"]["code"] == "invalid_args", tool
        assert result["error"]["details"]["kind"] == kind, tool

        assert Enum.any?(
                 result["error"]["details"]["issues"],
                 &(&1 == %{"path" => path, "code" => code})
               ),
               tool
      end)
    end

    test "logs one safe event for validation and none for other outcomes", %{
      conn: conn,
      raw: raw,
      key: key,
      subject: subject
    } do
      :ok = Logger.put_application_level(:emisar_web, :info)
      on_exit(fn -> Logger.delete_application_level(:emisar_web) end)

      sentinel = "sentinel_DO_NOT_LOG_7f6c"

      assert {:ok, _key} =
               ApiKeys.record_client_info(key, %{
                 "name" => "Claude Code #{sentinel}",
                 "version" => "2.3.4"
               })

      log =
        capture_log([level: :info], fn ->
          body =
            conn
            |> put_req_header("user-agent", "emisar-mcp/1.2.3 #{sentinel}")
            |> put_req_header("emisar-attestation", sentinel)
            |> put_req_header(
              "emisar-client-metadata",
              Jason.encode!(%{"device" => sentinel})
            )
            |> authorize(raw)
            |> rpc("tools/call", %{
              "name" => "list_packs",
              "arguments" => %{
                sentinel => %{
                  "reason" => sentinel,
                  "runner_refs" => [sentinel]
                }
              }
            })
            |> json_response(200)

          assert get_in(body, ["result", "structuredContent", "error", "code"]) ==
                   "invalid_args"
        end)

      assert length(String.split(log, "mcp.validation_failed")) == 2
      assert log =~ "mcp_tool=list_packs"
      assert log =~ "mcp_validation_stage=arguments"
      assert log =~ "mcp_validation_kind=unknown"
      assert log =~ "mcp_validation_issues=$:unknown"
      assert log =~ "mcp_client_name=claude"
      assert log =~ "mcp_client_version=2.3.4"
      assert log =~ "mcp_bridge_version=1.2.3"
      assert log =~ "mcp_client_lineage="
      assert log =~ ~r/mcp_call_fingerprint=[0-9a-f]{64}/
      refute log =~ sentinel
      refute log =~ raw

      field_log =
        capture_log([level: :info], fn ->
          body =
            build_conn()
            |> authorize(raw)
            |> rpc("tools/call", %{
              "name" => "list_packs",
              "arguments" => %{"limit" => "50"}
            })
            |> json_response(200)

          assert get_in(body, ["result", "structuredContent", "error", "code"]) ==
                   "invalid_args"
        end)

      assert field_log =~ "mcp_validation_issues=$.limit:type"

      clean_log =
        capture_log([level: :info], fn ->
          success =
            build_conn()
            |> authorize(raw)
            |> rpc("ping")
            |> json_response(200)

          assert success["result"] == %{}

          unknown =
            build_conn()
            |> authorize(raw)
            |> rpc("tools/call", %{"name" => sentinel, "arguments" => %{}})
            |> json_response(200)

          assert get_in(unknown, ["result", "structuredContent", "error", "code"]) ==
                   "unknown_tool"

          invalid_operation =
            build_conn()
            |> authorize(raw)
            |> put_req_header("emisar-operation-id", "invalid")
            |> rpc("tools/call", %{
              "name" => "run_action",
              "arguments" => %{
                "action_id" => "linux.uptime",
                "pack_ref" => "linux@1.0.0/sha256:" <> String.duplicate("a", 64),
                "runner_refs" => ["node~" <> String.duplicate("a", 32)],
                "args" => %{},
                "reason" => "Inspect uptime"
              }
            })
            |> json_response(200)

          assert get_in(
                   invalid_operation,
                   ["result", "structuredContent", "error", "code"]
                 ) == "invalid_operation"

          {:ok, audit_raw, _audit_key} =
            ApiKeys.create_key(%{name: "audit", kind: :audit_export}, subject)

          denied =
            build_conn()
            |> authorize(audit_raw)
            |> rpc("tools/list")
            |> json_response(200)

          assert denied["error"]["code"] == -32_002
        end)

      refute clean_log =~ "mcp.validation_failed"
      assert clean_log =~ "mcp.unknown_tool"
      assert clean_log =~ "mcp_unknown_tool_shape=other"
      assert clean_log =~ ~r/mcp_call_fingerprint=[0-9a-f]{64}/
      refute clean_log =~ sentinel
      refute clean_log =~ raw
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

  describe "initialize and protocol lifecycle" do
    test "negotiates supported protocol versions and fixed capabilities", %{raw: raw} do
      for version <- ~w(2025-11-25 2025-06-18) do
        body =
          build_conn()
          |> authorize(raw)
          |> rpc("initialize", %{"protocolVersion" => version})
          |> json_response(200)

        assert body["result"]["protocolVersion"] == version
        assert body["result"]["serverInfo"]["name"] == "emisar"
        assert get_in(body, ["result", "capabilities", "tools", "listChanged"]) == false
      end

      legacy =
        build_conn()
        |> authorize(raw)
        |> rpc("initialize", %{"protocolVersion" => "2024-11-05"})
        |> json_response(200)

      assert legacy["result"]["protocolVersion"] == "2025-11-25"
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

      assert body["result"]["instructions"] =~ "recover through its operation ID"

      reloaded = Repo.get!(ApiKey, key.id)

      assert reloaded.last_client_info == %{
               "name" => "Claude Code",
               "title" => "Claude",
               "version" => "1.2.3"
             }
    end

    test "the stateless endpoint never assigns or echoes an MCP session id", %{raw: raw} do
      initialize =
        build_conn()
        |> authorize(raw)
        |> put_req_header("mcp-session-id", "client-invented")
        |> rpc("initialize")

      assert get_resp_header(initialize, "mcp-session-id") == []

      ping =
        build_conn()
        |> authorize(raw)
        |> put_req_header("mcp-session-id", "client-invented")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> rpc("ping")

      assert get_resp_header(ping, "mcp-session-id") == []
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
