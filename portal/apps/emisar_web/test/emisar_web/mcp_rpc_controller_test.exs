defmodule EmisarWeb.McpRpcControllerTest do
  @moduledoc """
  Covers POST /api/mcp/rpc — the MCP-over-HTTP / JSON-RPC endpoint.
  Same Bearer-token auth as the REST surface; same Service module
  under the hood. Tests focus on the JSON-RPC envelope, the synthetic
  wait_for_run tool, and MCP content-block rendering.
  """

  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, ApiKeys, Policies, Repo, Runners}
  alias Emisar.Catalog.RunnerAction
  alias Emisar.Runners.Runner

  defp unique, do: System.unique_integer([:positive])

  defp setup_account do
    {:ok, user} =
      Accounts.register_user(%{
        email: "owner-#{unique()}@example.com",
        full_name: "Test Owner",
        password: "very-long-password-1234"
      })

    {:ok, user} = Accounts.confirm_user(user)

    {:ok, account} =
      Accounts.create_account_with_owner(
        %{name: "acct-#{unique()}", slug: "acct-#{unique()}", plan: "free"},
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

  defp make_runner!(account, opts \\ []) do
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
        first_seen_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
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
end
