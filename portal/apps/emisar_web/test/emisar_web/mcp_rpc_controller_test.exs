defmodule EmisarWeb.MCPRpcControllerTest do
  @moduledoc """
  Covers POST /api/mcp/rpc — the MCP-over-HTTP / JSON-RPC endpoint.
  Same Bearer-token auth as the REST surface; same Service module
  under the hood. Tests focus on the JSON-RPC envelope, the synthetic
  wait_for_run tool, and MCP content-block rendering.
  """

  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, ApiKeys, Policies, Repo, Runners, Runs, Users}
  alias Emisar.Catalog.RunnerAction
  alias Emisar.Runners.Runner

  defp unique, do: System.unique_integer([:positive])

  defp setup_account do
    {:ok, user} =
      Users.register_user(%{
        email: "owner-#{unique()}@example.com",
        full_name: "Test Owner",
        password: "very-long-password-1234"
      })

    user = Emisar.Fixtures.confirm_user(user)

    {:ok, account} =
      Accounts.create_account_with_owner(
        %{name: "acct-#{unique()}", slug: "acct-#{unique()}"},
        user
      )

    if Policies.peek_policy_for_account(account.id) == nil do
      {:ok, _} =
        Policies.seed_policy(account.id, user.id, %{
          "schema_version" => 2,
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "allow",
            "critical" => "allow"
          },
          "overrides" => []
        })
    end

    {account, user}
  end

  defp make_runner!(account, opts) do
    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: opts[:name] || "runner-#{unique()}",
        external_id: Ecto.UUID.generate(),
        group: opts[:group] || "default",
        hostname: opts[:hostname] || "host-#{unique()}",
        labels: %{},
        runner_version: "0.1.0"
      })
      |> Repo.insert()

    {:ok, runner} = Runners.connect_runner(runner)
    runner
  end

  defp advertise_action!(runner, opts) do
    {:ok, action} =
      RunnerAction.Changeset.upsert(%{
        account_id: runner.account_id,
        runner_id: runner.id,
        action_id: opts[:action_id] || "linux.uptime",
        pack_id: opts[:pack_id] || "linux-core",
        title: opts[:title] || "Uptime",
        kind: "exec",
        risk: opts[:risk] || "low",
        description: opts[:description] || "Reports uptime.",
        side_effects: [],
        args_schema: opts[:args_schema] || %{"args" => []},
        first_seen_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })
      |> Repo.insert()

    action
  end

  defp make_api_key!(account, user, opts \\ []) do
    subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

    {:ok, raw, _key} =
      ApiKeys.create_key(
        %{
          name: "key-#{unique()}",
          scopes: opts[:scopes] || ["actions:read", "actions:execute"],
          runner_filter: opts[:runner_filter] || [],
          runner_group_filter: opts[:runner_group_filter] || []
        },
        subject
      )

    raw
  end

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    body = %{jsonrpc: "2.0", id: id, method: method, params: params}

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp/rpc", Jason.encode!(body))
  end

  setup do
    {account, user} = setup_account()
    {:ok, account: account, user: user}
  end

  describe "auth" do
    test "rejects missing bearer with JSON-RPC unauthorized", %{conn: conn} do
      body =
        conn
        |> rpc("initialize")
        |> json_response(401)

      assert body["jsonrpc"] == "2.0"
      assert body["error"]["code"] == -32001
    end
  end

  describe "initialize" do
    test "returns protocolVersion + serverInfo + capabilities",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("initialize")
        |> json_response(200)

      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2024-11-05"
      assert body["result"]["serverInfo"]["name"] == "emisar"
      assert get_in(body, ["result", "capabilities", "tools", "listChanged"]) == false
    end

    test "includes an instructions guide covering error recovery",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("initialize")
        |> json_response(200)

      instructions = body["result"]["instructions"]
      assert is_binary(instructions)
      # The guide must teach the recovery model the LLM kept guessing at:
      # pack trust, the snapshot-vs-live catalog, and reason-required.
      assert instructions =~ "pack_untrusted"
      assert instructions =~ "tools/list"
      assert instructions =~ "reason"
      # ...and where to find more capabilities + how to add them when a task
      # genuinely needs a pack that isn't installed.
      assert instructions =~ "emisar.dev/packs"
      assert instructions =~ "pack install"
    end

    test "captures the client's name + version from clientInfo (sanitized)",
         %{conn: conn, account: account, user: user} do
      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

      {:ok, raw, key} =
        ApiKeys.create_key(
          %{name: "generic-key", scopes: ["actions:read", "actions:execute"]},
          subject
        )

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("initialize", %{
        "clientInfo" => %{"name" => "Claude Code", "version" => "1.2.3", "junk" => "drop me"}
      })
      |> json_response(200)

      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      # Only the known string fields are kept; unknown keys are dropped.
      assert reloaded.last_client_info == %{"name" => "Claude Code", "version" => "1.2.3"}
    end

    test "hands the client an Mcp-Session-Id (reusing one it already sent)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      fresh =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("initialize")

      assert [generated] = get_resp_header(fresh, "mcp-session-id")
      assert generated != ""

      reused =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("mcp-session-id", "existing-sess-123")
        |> rpc("initialize")

      assert get_resp_header(reused, "mcp-session-id") == ["existing-sess-123"]
    end
  end

  describe "ping" do
    test "returns empty result", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("ping", %{}, 7)
        |> json_response(200)

      assert body == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
    end
  end

  describe "tools/list" do
    test "returns advertised tools + the synthetic wait_for_run tool",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime")

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)

      assert %{"result" => %{"tools" => tools}} = body
      names = Enum.map(tools, & &1["name"])
      assert "linux.uptime" in names
      assert "wait_for_run" in names
    end

    test "requires actions:read scope", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["audit:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)

      assert body["error"]["code"] == -32002
      assert body["error"]["data"]["required"] == "actions:read"
    end
  end

  describe "tools/call" do
    test "dispatches an action; returns content blocks + isError=false",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          # wait=0 short-circuits the long-poll — the fixture has no
          # real runner process to drive the run to terminal.
          "arguments" => %{"runner" => "host-1", "reason" => "smoke", "wait" => "0"}
        })
        |> json_response(200)

      assert is_list(body["result"]["content"])
      assert body["result"]["isError"] == false
    end

    test "records the Mcp-Session-Id header on the dispatched run",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("mcp-session-id", "sess-abc-123")
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        "arguments" => %{"runner" => "host-1", "reason" => "smoke", "wait" => "0"}
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert run.mcp_session_id == "sess-abc-123"
    end

    test "unknown action returns isError content block",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "nope.no_such",
          "arguments" => %{"reason" => "x"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      content_text = body["result"]["content"] |> Enum.map_join(" ", & &1["text"])
      assert content_text =~ "Action not found"
    end

    test "missing tool name yields JSON-RPC -32602",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "", "arguments" => %{}})
        |> json_response(200)

      assert body["error"]["code"] == -32602
    end
  end

  describe "notifications" do
    test "no body, status 202", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)
      # JSON-RPC notification: omit id
      payload = %{jsonrpc: "2.0", method: "notifications/initialized"}

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/mcp/rpc", Jason.encode!(payload))
      |> response(202)
    end
  end

  describe "unknown method" do
    test "returns -32601", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("not/a_real_method")
        |> json_response(200)

      assert body["error"]["code"] == -32601
    end
  end

  describe "runbook tools" do
    test "tools/list includes the read-only runbook tools",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])

      assert "list_runbooks" in names
      assert "get_runbook" in names
    end

    test "list_runbooks + get_runbook expose a published runbook with resolved runner names",
         %{conn: conn, account: account, user: user} do
      make_runner!(account, name: "edge-1", group: "edge-eu")
      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "EU health",
            "name" => "EU health",
            "slug" => "eu-health",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "uptime",
                  "action_id" => "linux.uptime",
                  "args" => %{"window" => "5m"},
                  "runner_selector" => %{"group" => ["edge-eu"]}
                }
              ]
            }
          },
          subject
        )

      {:ok, _} = Emisar.Runbooks.publish(runbook, subject)

      raw = make_api_key!(account, user)
      auth = &put_req_header(&1, "authorization", "Bearer " <> raw)

      list_text =
        conn
        |> auth.()
        |> rpc("tools/call", %{"name" => "list_runbooks", "arguments" => %{}})
        |> json_response(200)
        |> content_text()

      assert list_text =~ "eu-health"

      detail =
        conn
        |> auth.()
        |> rpc("tools/call", %{
          "name" => "get_runbook",
          "arguments" => %{"runbook" => "eu-health"}
        })
        |> json_response(200)

      assert detail["result"]["isError"] == false
      text = content_text(detail)
      assert text =~ "linux.uptime"
      # The group selector is resolved to the connected runner's name.
      assert text =~ "edge-1"
      assert text =~ "window"
    end

    test "get_runbook reports a clear error for an unknown slug",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "get_runbook", "arguments" => %{"runbook" => "nope"}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "not found"
    end

    test "an emo- OAuth token (the Claude/ChatGPT connector path) sees the runbook tools",
         %{conn: conn, account: account, user: user} do
      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

      # Drive the exact OAuth flow Claude.ai / ChatGPT connectors run: register
      # a PKCE client, issue an auth code, exchange it for an emo- access token.
      redirect = "https://claude.ai/api/mcp/auth_callback"

      {:ok, client} =
        Emisar.OAuth.register_client(%{"client_name" => "Claude", "redirect_uris" => [redirect]})

      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

      {:ok, code} =
        Emisar.OAuth.issue_code(
          client,
          %{
            "redirect_uri" => redirect,
            "code_challenge" => challenge,
            "code_challenge_method" => "S256",
            "scope" => "mcp offline_access",
            "resource" => "https://emisar.dev/api/mcp/rpc"
          },
          subject
        )

      {:ok, tokens} =
        Emisar.OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => redirect,
          "code_verifier" => verifier
        })

      assert "emo-" <> _ = tokens.access_token

      # tools/list, authenticated with the OAuth token, exposes the runbook tools.
      names =
        conn
        |> put_req_header("authorization", "Bearer " <> tokens.access_token)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])

      assert "list_runbooks" in names
      assert "get_runbook" in names
    end
  end

  defp content_text(body) do
    body
    |> get_in(["result", "content"])
    |> Enum.map_join("\n", & &1["text"])
  end

  describe "recent_runs tool" do
    test "tools/list includes the read-only recent_runs tool",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])

      assert "recent_runs" in names
    end

    test "an actions:read key gets its own dispatched runs back",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

      {:ok, raw, key} =
        ApiKeys.create_key(%{name: "reader-#{unique()}", scopes: ["actions:read"]}, subject)

      # A run this key dispatched (carries its api_key_id) so scope=own returns it.
      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{}
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{}})
        |> json_response(200)

      assert body["result"]["isError"] == false
      assert content_text(body) =~ run.id
      assert content_text(body) =~ "linux.uptime"
    end

    test "a numeric-string limit is accepted, not silently dropped to the default",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      # Some MCP clients stringify args; "5" must parse, not coerce to an error.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"limit" => "5"}})
        |> json_response(200)

      assert body["result"]["isError"] == false
    end

    test "an unrecognized scope errors instead of silently narrowing to own",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"scope" => "bogus"}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "scope"
    end

    test "an execute-only key calling recent_runs is refused with actions:read",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:execute"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{}})

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:read"}}} =
               json_response(conn, 200)
    end
  end

  describe "malformed frames + scope denials" do
    test "a non-2.0 frame is rejected with -32600", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(%{method: "ping"}))

      assert %{"error" => %{"code" => -32600}} = json_response(conn, 400)
    end

    test "tools/call without a tool name is -32602", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"arguments" => %{}})

      assert %{"error" => %{"code" => -32602}} = json_response(conn, 200)
    end

    test "a read-only key calling an action tool is refused with the required scope", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, [])
      _ = advertise_action!(runner, action_id: "linux.uptime")
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "linux_uptime", "arguments" => %{"reason" => "x"}})

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:execute"}}} =
               json_response(conn, 200)
    end

    test "an execute-only key calling wait_for_run is refused with actions:read", %{
      conn: conn,
      account: account,
      user: user
    } do
      raw = make_api_key!(account, user, scopes: ["actions:execute"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "wait_for_run", "arguments" => %{"run_id" => "x"}})

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:read"}}} =
               json_response(conn, 200)
    end
  end

  describe "wait_for_run argument + lookup errors" do
    test "missing run_id is an in-band tool error", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "wait_for_run", "arguments" => %{}})

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "requires `run_id`"
    end

    test "an unparseable timeout is an in-band tool error", %{
      conn: conn,
      account: account,
      user: user
    } do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => Ecto.UUID.generate(), "timeout" => "soon"}
        })

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "duration"
    end

    test "an unknown run id reads as not found", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => Ecto.UUID.generate(), "timeout" => ""}
        })

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "Run not found"
    end

    test "the long-poll returns the terminal result when the run finalizes mid-wait", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, [])
      raw = make_api_key!(account, user)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{}
        })

      # Finalize from another process shortly after the poll starts —
      # the await loop must wake on the run_updated broadcast, well
      # before the 5s timeout.
      test_pid = self()

      Task.start(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Emisar.Repo, test_pid, self())
        # Delay-injection in the WRITER (finalize lands mid-wait), not
        # poll-synchronization — the long-poll itself wakes on the broadcast.
        # credo:disable-for-next-line Emisar.Checks.TestNoProcessSleep
        Process.sleep(50)

        {:ok, _} =
          Runs.finalize_from_result(runner.id, %{
            "request_id" => run.request_id,
            "status" => "success",
            "exit_code" => 0,
            "stdout" => "up 3 days"
          })
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => run.id, "timeout" => "5s"}
        })

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == false
      assert content_text(body) =~ "exit_code=0"
    end

    test "a still-running run with zero wait reports waiting, not an error", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, [])
      raw = make_api_key!(account, user)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => run.id, "timeout" => ""}
        })

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == false
      assert content_text(body) =~ "still"
    end
  end

  describe "get_runbook argument errors" do
    test "missing runbook arg is an in-band tool error", %{
      conn: conn,
      account: account,
      user: user
    } do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "get_runbook", "arguments" => %{}})

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "requires `runbook`"
    end

    test "an unknown slug reads as not found", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "get_runbook", "arguments" => %{"runbook" => "ghost"}})

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "Runbook not found"
    end
  end
end
