defmodule EmisarWeb.McpControllerTest do
  @moduledoc """
  Covers the MCP HTTP surface end-to-end. Focuses on the runner-aware
  redesign: discovery via /runners, runner-enum in /tools' inputSchema,
  flat-body dispatch on /tools/:action_id, and visibility filtering by
  the API key's runner_filter.
  """

  use EmisarWeb.ConnCase, async: true

  import Ecto.Query

  alias Emisar.{Accounts, ApiKeys, Catalog, Policies, Repo, Runners}
  alias Emisar.Catalog.RunnerAction
  alias Emisar.Runners.Runner

  # -- Inline fixtures (Emisar.Fixtures isn't compiled into emisar_web's
  # test build; replicate the minimum we need) ------------------------

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

    # The account-creation flow seeds a policy already, but make
    # absolutely sure dispatch has something to evaluate against.
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
    name = opts[:name] || "runner-#{unique()}"

    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: name,
        external_id: Ecto.UUID.generate(),
        group: opts[:group] || "default",
        hostname: opts[:hostname] || "host-#{unique()}",
        labels: opts[:labels] || %{},
        runner_version: opts[:runner_version] || "0.1.0"
      })
      |> Repo.insert()

    {:ok, runner} = Runners.mark_connected(runner)
    runner
  end

  defp advertise_action!(runner, opts) do
    args_schema = opts[:args_schema] || %{"args" => []}

    {:ok, action} =
      RunnerAction.Changeset.upsert(%{
        account_id: runner.account_id,
        runner_id: runner.id,
        action_id: opts[:action_id] || "linux.uptime",
        pack_id: opts[:pack_id] || "linux-core",
        title: opts[:title] || "Uptime",
        kind: opts[:kind] || "exec",
        risk: opts[:risk] || "low",
        description: opts[:description] || "Reports uptime.",
        side_effects: opts[:side_effects] || [],
        args_schema: args_schema,
        first_seen_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.insert()

    action
  end

  defp make_api_key!(account, user, opts \\ []) do
    subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

    {:ok, raw, _key} =
      ApiKeys.create_key(%{
        name: "key-#{unique()}",
        scopes: opts[:scopes] || ["actions:read", "actions:execute"],
        runner_filter: opts[:runner_filter] || [],
        runner_group_filter: opts[:runner_group_filter] || []
      }, subject)

    raw
  end

  setup do
    {account, user} = setup_account()
    {:ok, account: account, user: user}
  end

  describe "GET /api/mcp/runners" do
    test "returns runners + their advertised actions", %{conn: conn, account: account, user: user} do
      runner_a = make_runner!(account, name: "db-prod-01", hostname: "10.0.5.12")
      runner_b = make_runner!(account, name: "db-prod-02", hostname: "10.0.5.13")

      advertise_action!(runner_a, action_id: "cassandra.repair", risk: "high")
      advertise_action!(runner_a, action_id: "cassandra.status", risk: "low")
      advertise_action!(runner_b, action_id: "cassandra.repair", risk: "high")

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)

      assert %{"runners" => runners} = body
      assert length(runners) == 2

      by_name = Map.new(runners, &{&1["name"], &1})

      assert by_name["db-prod-01"]["hostname"] == "10.0.5.12"
      assert by_name["db-prod-01"]["status"] == "connected"

      assert Enum.sort(by_name["db-prod-01"]["actions"] |> Enum.map(& &1["action_id"])) ==
               ["cassandra.repair", "cassandra.status"]

      assert by_name["db-prod-02"]["actions"] |> Enum.map(& &1["action_id"]) ==
               ["cassandra.repair"]
    end

    test "respects api_key.runner_filter", %{conn: conn, account: account, user: user} do
      runner_a = make_runner!(account, name: "in-filter")
      runner_b = make_runner!(account, name: "out-of-filter")
      advertise_action!(runner_a, action_id: "x")
      advertise_action!(runner_b, action_id: "y")

      raw = make_api_key!(account, user, runner_filter: [runner_a.id])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)

      assert [%{"name" => "in-filter"}] = body["runners"]
    end

    test "respects api_key.runner_group_filter — group-level allowlist",
         %{conn: conn, account: account, user: user} do
      # Two runners in `dba` group, one in `app`. A key scoped to the
      # `dba` group should see both DBA runners and reject the app
      # runner regardless of which specific runner ids exist.
      dba_a = make_runner!(account, name: "dba-01", group: "dba")
      dba_b = make_runner!(account, name: "dba-02", group: "dba")
      app = make_runner!(account, name: "app-01", group: "app")
      advertise_action!(dba_a, action_id: "x")
      advertise_action!(dba_b, action_id: "x")
      advertise_action!(app, action_id: "y")

      raw = make_api_key!(account, user, runner_group_filter: ["dba"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)

      names = body["runners"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["dba-01", "dba-02"]
    end

    test "runner_filter + runner_group_filter are additive (union)",
         %{conn: conn, account: account, user: user} do
      # A key with id-list [edge-01] AND group-list [dba] should see
      # both: anything in the dba group + the explicit edge-01 runner.
      dba = make_runner!(account, name: "dba-01", group: "dba")
      edge = make_runner!(account, name: "edge-01", group: "edge")
      _other = make_runner!(account, name: "other", group: "misc")
      advertise_action!(dba, action_id: "x")
      advertise_action!(edge, action_id: "y")

      raw =
        make_api_key!(account, user,
          runner_filter: [edge.id],
          runner_group_filter: ["dba"]
        )

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)

      names = body["runners"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["dba-01", "edge-01"]
    end

    test "401 without a Bearer token", %{conn: conn} do
      assert conn |> get(~p"/api/mcp/runners") |> json_response(401) ==
               %{"error" => "unauthorized"}
    end
  end

  describe "GET /api/mcp/tools" do
    test "one tool per action_id, with runner enum listing every advertiser", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner_a = make_runner!(account, name: "db-prod-01")
      runner_b = make_runner!(account, name: "db-prod-02")
      advertise_action!(runner_a, action_id: "shared.action")
      advertise_action!(runner_b, action_id: "shared.action")
      advertise_action!(runner_a, action_id: "solo.action")

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/tools")
        |> json_response(200)

      tools_by_name = Map.new(body["tools"], &{&1["name"], &1})

      shared = tools_by_name["shared.action"]
      assert shared["inputSchema"]["properties"]["runners"]["type"] == "array"
      assert shared["inputSchema"]["properties"]["runners"]["items"]["enum"] ==
               ["db-prod-01", "db-prod-02"]

      assert shared["inputSchema"]["properties"]["runners"]["maxItems"] == 2
      assert "runners" in shared["inputSchema"]["required"]

      solo = tools_by_name["solo.action"]
      assert solo["inputSchema"]["properties"]["runners"]["items"]["enum"] == ["db-prod-01"]
      assert solo["inputSchema"]["properties"]["runners"]["default"] == ["db-prod-01"]
      assert solo["inputSchema"]["properties"]["runners"]["maxItems"] == 1
      refute "runners" in solo["inputSchema"]["required"]
    end

    test "emits valid JSON Schema 2020-12 for every emisar arg type", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "host")

      advertise_action!(runner,
        action_id: "showcase.every_arg_type",
        args_schema: %{
          "args" => [
            %{"name" => "mode", "type" => "string", "required" => true,
              "validation" => %{"enum" => ["fast", "slow"]}},
            %{"name" => "port", "type" => "integer", "default" => 8080,
              "validation" => %{"allowed" => [80, 443, 8080]}},
            %{"name" => "ratio", "type" => "number",
              "validation" => %{"min" => 0, "max" => 1}},
            %{"name" => "verbose", "type" => "boolean", "default" => false},
            %{"name" => "window", "type" => "duration", "default" => "5m"},
            %{"name" => "tags", "type" => "string_array",
              "validation" => %{"max_items" => 16}},
            %{"name" => "ids", "type" => "integer_array"},
            %{"name" => "mystery", "type" => "unknown_emisar_type"}
          ]
        }
      )

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/tools")
        |> json_response(200)

      [%{"inputSchema" => schema}] = body["tools"]

      assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
      assert schema["type"] == "object"
      assert schema["additionalProperties"] == false

      props = schema["properties"]

      # Every property must declare a valid JSON Schema primitive type.
      for {name, prop} <- props do
        assert prop["type"] in ~w(string integer number boolean array),
               "#{name} has invalid type: #{inspect(prop["type"])}"
      end

      # No nil leaking anywhere — the bug that triggered Claude's
      # 400 "tools.N.custom.input_schema invalid" rejection.
      assert_no_nil_values(schema)

      assert props["mode"]["enum"] == ["fast", "slow"]
      assert props["port"]["enum"] == [80, 443, 8080]
      assert props["port"]["default"] == 8080
      assert props["ratio"]["minimum"] == 0
      assert props["ratio"]["maximum"] == 1
      assert props["verbose"]["type"] == "boolean"
      assert props["window"]["type"] == "string"
      assert props["window"]["pattern"] =~ ~r/ms|s|m|h/
      assert props["tags"] == %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 16}
      assert props["ids"] == %{"type" => "array", "items" => %{"type" => "integer"}}
      # Unknown type widens to string.
      assert props["mystery"]["type"] == "string"

      assert "reason" in schema["required"]
      assert "mode" in schema["required"]
    end

    test "hides actions whose only runner is outside the key filter", %{
      conn: conn,
      account: account,
      user: user
    } do
      visible = make_runner!(account, name: "visible")
      hidden = make_runner!(account, name: "hidden")
      advertise_action!(visible, action_id: "visible.action")
      advertise_action!(hidden, action_id: "hidden.action")

      raw = make_api_key!(account, user, runner_filter: [visible.id])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/tools")
        |> json_response(200)

      names = Enum.map(body["tools"], & &1["name"])
      assert "visible.action" in names
      refute "hidden.action" in names
    end

    test "every tool exposes an optional `idempotency_key` property the LLM can set", %{
      conn: conn,
      account: account,
      user: user
    } do
      # Layer 2 contract: the inputSchema advertises an idempotency_key
      # property so an LLM that recognises it can opt into at-most-once
      # retry semantics. It must NOT be in `required` — the common case
      # is to omit it and let the bridge's per-call header (Layer 1)
      # handle transport retries invisibly.
      runner = make_runner!(account, name: "lone-runner")
      advertise_action!(runner, action_id: "linux.uptime")
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/tools")
        |> json_response(200)

      [tool] = body["tools"]
      idem = tool["inputSchema"]["properties"]["idempotency_key"]

      assert idem["type"] == "string"
      assert is_binary(idem["description"]) and idem["description"] != ""
      refute "idempotency_key" in tool["inputSchema"]["required"]
    end
  end

  describe "POST /api/mcp/tools/:action_id" do
    setup %{account: account} do
      runner = make_runner!(account, name: "db-prod-01")
      advertise_action!(runner, action_id: "linux.uptime")
      {:ok, runner: runner}
    end

    test "dispatches with flat body (runners array + reason + args)", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => [runner.name],
          "reason" => "ad-hoc check"
        })
        |> json_response(202)

      assert %{"runs" => [run_entry]} = body
      assert run_entry["runner"] == runner.name
      assert run_entry["status"] in ["running", "sent", "success"]
      {:ok, run} = Emisar.Runs.fetch_run_by_id(run_entry["run_id"] || run_entry["id"], Emisar.Auth.Subject.system(account))
      assert run.runner_id == runner.id
      assert run.action_id == "linux.uptime"
    end

    test "single-string `runner` is normalised into a one-element array", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runner" => runner.name,
          "reason" => "compat check"
        })
        |> json_response(202)

      assert %{"runs" => [_]} = body
    end

    test "fans out to all listed runners in input order", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner_a
    } do
      runner_b = make_runner!(account, name: "db-prod-02")
      runner_c = make_runner!(account, name: "db-prod-03")
      advertise_action!(runner_b, action_id: "linux.uptime")
      advertise_action!(runner_c, action_id: "linux.uptime")

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => [runner_a.name, runner_b.name, runner_c.name],
          "reason" => "fan-out check"
        })
        |> json_response(202)

      assert Enum.map(body["runs"], & &1["runner"]) ==
               [runner_a.name, runner_b.name, runner_c.name]

      # Each runner got its own action_run row.
      runner_ids =
        Enum.map(body["runs"], fn entry ->
          {:ok, r} = Emisar.Runs.fetch_run_by_id(entry["run_id"] || entry["id"], Emisar.Auth.Subject.system(account))
          r.runner_id
        end)

      assert Enum.sort(runner_ids) == Enum.sort([runner_a.id, runner_b.id, runner_c.id])
    end

    test "auto-picks the runner when only one advertises the action", %{
      conn: conn,
      account: account,
      user: user
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{"reason" => "ad-hoc"})
        |> json_response(202)

      assert %{"runs" => [%{"status" => status}]} = body
      assert status in ["running", "sent", "success"]
    end

    test "400 when multiple runners advertise + `runners` omitted", %{
      conn: conn,
      account: account,
      user: user
    } do
      other = make_runner!(account, name: "db-prod-02")
      advertise_action!(other, action_id: "linux.uptime")

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{"reason" => "ad-hoc"})
        |> json_response(400)

      assert body["error"] == "runner_required"
      assert Enum.sort(body["candidates"]) == ["db-prod-01", "db-prod-02"]
    end

    test "400 when too many runners are requested in one call", %{
      conn: conn,
      account: account,
      user: user
    } do
      # 17 fake names → exceeds the @max_runners_per_call cap of 16.
      raw = make_api_key!(account, user)
      many = for i <- 1..17, do: "fake-#{i}"

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => many,
          "reason" => "stress"
        })
        |> json_response(400)

      assert body["error"] == "too_many_runners"
    end

    test "404 when an unknown runner is in the list", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => [runner.name, "ghost"],
          "reason" => "ad-hoc"
        })
        |> json_response(404)

      assert body["error"] == "runner_not_found"
      assert body["runner"] == "ghost"
    end

    test "403 when one of the listed runners is outside the key filter", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      other = make_runner!(account, name: "db-prod-02")
      advertise_action!(other, action_id: "linux.uptime")

      raw = make_api_key!(account, user, runner_filter: [runner.id])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => ["db-prod-02"],
          "reason" => "ad-hoc"
        })
        |> json_response(403)

      assert body["error"] == "runner_not_in_key_filter"
      assert body["runner"] == "db-prod-02"
    end

    test "missing reason surfaces inside the per-runner result entry", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{"runners" => [runner.name]})
        |> json_response(202)

      assert %{"runs" => [entry]} = body
      assert entry["error"] == "reason_required"
    end

    test "missing scope returns 403", %{conn: conn, account: account, user: user, runner: runner} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => [runner.name],
          "reason" => "x"
        })
        |> json_response(403)

      assert body["error"] == "missing_scope"
    end

    test "runner_not_found error includes actionable message", %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => ["nonexistent-host"],
          "reason" => "x"
        })
        |> json_response(404)

      assert body["error"] == "runner_not_found"
      assert body["runner"] == "nonexistent-host"
      assert body["message"] =~ "GET /api/mcp/runners"
    end

    test "runner_not_allowed includes specific reason + message", %{conn: conn, account: account, user: user} do
      # Two runners; only the first is in the key's filter.
      in_filter = make_runner!(account, name: "in-filter")
      out = make_runner!(account, name: "out-of-filter")
      advertise_action!(in_filter, action_id: "linux.uptime")
      advertise_action!(out, action_id: "linux.uptime")
      raw = make_api_key!(account, user, runner_filter: [in_filter.id])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => ["out-of-filter"],
          "reason" => "x"
        })
        |> json_response(403)

      assert body["error"] == "runner_not_in_key_filter"
      assert body["reason"] =~ "runner_filter"
      assert body["message"] =~ "API key"
    end

    test "action_not_found distinguished from no_runner_in_scope", %{conn: conn, account: account, user: user} do
      # Truly missing action_id (nobody advertises it) → action_not_found 404.
      # The shared setup already gave us a runner advertising linux.uptime.
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/totally.unknown", %{"reason" => "x"})
        |> json_response(404)

      assert body["error"] == "action_not_found"
      assert body["action_id"] == "totally.unknown"
      assert body["message"] =~ "/tools"
    end

    test "no_runner_in_scope: action exists but filter blocks every runner", %{conn: conn, account: account, user: user} do
      # Action exists on a runner that the key's filter excludes — should
      # land as `no_runner_in_scope` (403), not `action_not_found` (404).
      blocked = make_runner!(account, name: "blocked")
      visible = make_runner!(account, name: "visible")
      advertise_action!(blocked, action_id: "secret.action")
      advertise_action!(visible, action_id: "different.action")
      raw = make_api_key!(account, user, runner_filter: [visible.id])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/secret.action", %{"reason" => "x"})
        |> json_response(403)

      assert body["error"] == "no_runner_in_scope"
      assert body["message"] =~ "API key"
    end

    test "dispatch to offline runner queues + surfaces warning", %{conn: conn, account: account, user: user} do
      # Mark the runner as disconnected, then dispatch — should still
      # succeed (run is queued), but include warning fields so the LLM
      # can tell the user.
      runner = make_runner!(account, name: "offline-host")
      advertise_action!(runner, action_id: "linux.uptime")

      {:ok, _} = Runners.mark_disconnected(runner, "test-disconnect")

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => ["offline-host"],
          "reason" => "x"
        })
        |> json_response(202)

      assert [run] = body["runs"]
      assert run["warning"] == "runner_offline"
      assert run["warning_message"] =~ "offline-host"
    end

    test "Idempotency-Key header — same key replays the original run (Layer 1)", %{
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)
      key = "idem-#{unique()}"

      first = dispatch_with_idempotency(raw, runner, "first call", header: key)

      # Build a fresh conn — Phoenix.ConnTest reuses the same conn across
      # piped requests, so a second `post` on the same conn would replay
      # against the same connection state, which isn't what callers do.
      second = dispatch_with_idempotency(raw, runner, "retried call", header: key)

      assert run_id_of(hd(first["runs"])) == run_id_of(hd(second["runs"]))
    end

    test "idempotency_key tool arg — same value replays (Layer 2, LLM-controlled)", %{
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)
      key = "model-retry-#{unique()}"

      first = dispatch_with_idempotency(raw, runner, "first", body: key)
      second = dispatch_with_idempotency(raw, runner, "second", body: key)

      assert run_id_of(hd(first["runs"])) == run_id_of(hd(second["runs"]))
    end

    test "body `idempotency_key` wins over `Idempotency-Key` header", %{
      account: account,
      user: user,
      runner: runner
    } do
      # Same body key + different header on each call: if body wins
      # (it should — the LLM's retry intent beats the bridge's
      # transport key) both calls map to the same run.
      raw = make_api_key!(account, user)
      body_key = "body-wins-#{unique()}"

      first =
        dispatch_with_idempotency(raw, runner, "first",
          body: body_key,
          header: "header-a-#{unique()}"
        )

      second =
        dispatch_with_idempotency(raw, runner, "second",
          body: body_key,
          header: "header-b-#{unique()}"
        )

      assert run_id_of(hd(first["runs"])) == run_id_of(hd(second["runs"]))
    end

    test "idempotency_key never leaks into the run's recorded args", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "args-leak-host")
      # Action takes one real arg so we can distinguish it from the
      # control field in the stored args map.
      advertise_action!(runner,
        action_id: "linux.touch",
        args_schema: %{
          "args" => [%{"name" => "path", "type" => "string", "required" => true}]
        }
      )

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.touch", %{
          "runners" => [runner.name],
          "reason" => "x",
          "path" => "/tmp/marker",
          "idempotency_key" => "should-not-leak-#{unique()}"
        })
        |> json_response(202)

      [run_entry] = body["runs"]
      run_id = run_id_of(run_entry)

      {:ok, run} =
        Emisar.Runs.fetch_run_by_id(run_id, Emisar.Auth.Subject.system(account))

      assert run.args == %{"path" => "/tmp/marker"}
      refute Map.has_key?(run.args, "idempotency_key")
    end

    test "blank / whitespace / over-long idempotency_key degrades to no-key (no replay)", %{
      account: account,
      user: user,
      runner: runner
    } do
      # `sanitize_idempotency_key/1` filters these so a chatty / buggy
      # client can't fill the unique index with garbage or accidentally
      # request replay semantics by sending an empty string. Each call
      # below has to dispatch a FRESH run, even though the body field is
      # technically present.
      raw = make_api_key!(account, user)

      for {label, key} <- [
            {"empty string", ""},
            {"whitespace only", "   "},
            {"over the 200-char cap", String.duplicate("x", 201)}
          ] do
        first = dispatch_with_idempotency(raw, runner, "first #{label}", body: key)
        second = dispatch_with_idempotency(raw, runner, "second #{label}", body: key)

        # Two distinct runs — sanitisation rejected the key on BOTH
        # calls, so neither side hit the replay path.
        refute run_id_of(hd(first["runs"])) == run_id_of(hd(second["runs"])),
               "expected fresh dispatches for #{label}, got the same run twice"
      end
    end

    test "fan-out: one key + N runners produces N rows; same retry replays them all", %{
      conn: conn,
      account: account,
      user: user
    } do
      # `per_runner_idempotency_key/3` suffixes the caller's key with the
      # runner id so each runner's row claims a distinct slot in the
      # `(api_key_id, idempotency_key)` unique index. A retry with the
      # same runner set + same base key replays each row individually.
      r1 = make_runner!(account, name: "fanout-a")
      r2 = make_runner!(account, name: "fanout-b")
      advertise_action!(r1, action_id: "shared.act")
      advertise_action!(r2, action_id: "shared.act")
      raw = make_api_key!(account, user)
      key = "fanout-#{unique()}"

      first =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/shared.act", %{
          "runners" => ["fanout-a", "fanout-b"],
          "reason" => "x",
          "idempotency_key" => key
        })
        |> json_response(202)

      second =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/shared.act", %{
          "runners" => ["fanout-a", "fanout-b"],
          "reason" => "x",
          "idempotency_key" => key
        })
        |> json_response(202)

      ids_by_runner = fn body ->
        body["runs"]
        |> Enum.map(&{&1["runner"], run_id_of(&1)})
        |> Map.new()
      end

      first_ids = ids_by_runner.(first)
      second_ids = ids_by_runner.(second)

      # Distinct run rows per runner...
      refute first_ids["fanout-a"] == first_ids["fanout-b"]
      # ...and each runner's row replays on retry instead of inserting a duplicate.
      assert first_ids == second_ids
    end
  end

  describe "GET /api/mcp/runs/:id (wait_for_run polling)" do
    test "returns the run state immediately when no wait param", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "runner-1")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "pending"
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}")
        |> json_response(200)

      assert body["id"] == run.id
      assert body["status"] == "pending"
    end

    test "long-poll returns when run reaches terminal state", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "runner-1")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "sent"
        })

      # Background worker flips the run to terminal mid-poll so we
      # exercise the long-poll wake-up path (not the immediate-return
      # path the previous test covers). `start_supervised!` makes the
      # task part of the test tree so teardown awaits it cleanly, and
      # `Sandbox.allow` lets it use the test's sandbox connection.
      #
      # Times are generous: 80ms sleep + 5s wait gives the scheduler
      # ~6× safety margin under CI jitter — small enough the test is
      # fast on a hot machine, big enough it never races.
      parent = self()

      Task.Supervisor.start_child(EmisarWeb.TaskSupervisor, fn ->
        Process.sleep(80)
        Ecto.Adapters.SQL.Sandbox.allow(Emisar.Repo, parent, self())

        Emisar.Repo.update_all(
          from(r in Emisar.Runs.ActionRun, where: r.id == ^run.id),
          set: [status: "success", exit_code: 0]
        )
      end)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}?wait=5s")
        |> json_response(200)

      assert body["status"] == "success"
    end

    test "failed run surfaces exit_code, stderr, and error_message for the bridge", %{
      conn: conn,
      account: account,
      user: user
    } do
      # This is the contract the MCP bridge depends on to render
      # actionable failure output instead of "emisar status: error".
      # If any of these fields drop out of the response payload the
      # bridge's renderRunBlocks has nothing to show the LLM.
      runner = make_runner!(account, name: "runner-1")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "pending"
        })

      # create_changeset doesn't cast exit_code/error_message — the
      # production path goes through transition_changeset. Bypass with
      # a direct update so we can pin the failure-payload shape.
      Repo.update_all(
        from(r in Emisar.Runs.ActionRun, where: r.id == ^run.id),
        set: [
          status: "failed",
          exit_code: 1,
          error_message: "command exited with code 1",
          finished_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        ]
      )

      {:ok, run} = Emisar.Runs.fetch_run_by_id(run.id, Emisar.Auth.Subject.system(account))

      {:ok, _} =
        Emisar.Runs.append_event(run, %{
          seq: 1,
          kind: "progress",
          stream: "stderr",
          payload: %{"chunk" => "nginx: bind() to 0.0.0.0:80 failed (98: Address already in use)\n"}
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}")
        |> json_response(200)

      assert body["status"] == "failed"
      assert body["exit_code"] == 1
      assert body["error_message"] == "command exited with code 1"
      assert body["stderr"] =~ "Address already in use"
    end

    test "long-poll returns 202 + waiting=timeout when deadline passes", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "runner-1")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "sent"
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}?wait=200ms")
        |> json_response(202)

      assert body["waiting"] == "timeout"
      assert body["status"] == "sent"
      assert is_binary(body["tip"])
    end

    test "rejects an invalid wait param", %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "runner-1")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "pending"
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}?wait=bogus")
        |> json_response(400)

      assert body["error"] == "invalid_wait"
    end
  end

  # POST /tools/:id responses use different shapes per status. Running
  # runs land in the full payload (`id` field); pending-approval / error
  # entries use `run_id`. Tests don't care which — they just want the
  # row identifier — so unify both via this helper.
  defp run_id_of(%{"id" => id}) when is_binary(id), do: id
  defp run_id_of(%{"run_id" => id}) when is_binary(id), do: id

  # Issue a single `linux.uptime` dispatch with the supplied idempotency
  # key(s). `:header` sets the HTTP `Idempotency-Key` header (Layer 1);
  # `:body` sets the in-args `idempotency_key` (Layer 2). Each call uses
  # a fresh conn so we exercise the same code path real callers do —
  # the controller mints/reads the key per request, not per pipe.
  defp dispatch_with_idempotency(raw, runner, reason, opts) do
    params = %{"runners" => [runner.name], "reason" => reason}

    params =
      case Keyword.get(opts, :body) do
        nil -> params
        key -> Map.put(params, "idempotency_key", key)
      end

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> raw)

    conn =
      case Keyword.get(opts, :header) do
        nil -> conn
        key -> put_req_header(conn, "idempotency-key", key)
      end

    conn
    |> post(~p"/api/mcp/tools/linux.uptime", params)
    |> json_response(202)
  end

  defp pick_key(account, raw) do
    Emisar.ApiKeys.peek_api_key_by_secret(raw)
    |> case do
      %{id: _} = k -> k
      _ -> raise "key not found for raw secret in account #{account.id}"
    end
  end

  # Recursively walks a JSON-decoded structure and asserts no nil
  # values are present — strict JSON Schema 2020-12 validators reject
  # `"type": null` (and similar), which is what triggered the prod bug.
  defp assert_no_nil_values(value) when is_map(value) do
    for {k, v} <- value do
      refute is_nil(v), "unexpected nil at key #{inspect(k)}"
      assert_no_nil_values(v)
    end
  end

  defp assert_no_nil_values(value) when is_list(value) do
    for v <- value do
      refute is_nil(v), "unexpected nil in list"
      assert_no_nil_values(v)
    end
  end

  defp assert_no_nil_values(_), do: :ok

  # Suppress unused-alias warnings — these are referenced via `~p` /
  # the inline fixtures above but the compiler can't always see it.
  _ = {Catalog, Runners, Repo}
end
