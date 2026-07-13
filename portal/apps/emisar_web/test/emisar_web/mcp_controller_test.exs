defmodule EmisarWeb.MCPControllerTest do
  @moduledoc """
  Covers the MCP HTTP surface end-to-end. Focuses on the runner-aware
  redesign: discovery via /runners, runner-enum in /tools' inputSchema,
  flat-body dispatch on /tools/:action_id, and visibility filtering by
  the key creator's own runner scope.
  """

  use EmisarWeb.ConnCase, async: true
  import Ecto.Query
  alias Emisar.{Accounts, ApiKeys, Catalog, Policies, Repo, Runners, Users}
  alias Emisar.Catalog.RunnerAction
  alias Emisar.Runners.Runner
  alias EmisarWeb.MCP.Service

  # -- Inline fixtures (Emisar.Fixtures isn't compiled into emisar_web's
  # test build; replicate the minimum we need) ------------------------

  defp unique, do: System.unique_integer([:positive])

  defp setup_account do
    {:ok, user} =
      Users.register_user(%{
        email: "owner-#{unique()}@example.com",
        full_name: "Test Owner"
      })

    user = Fixtures.Users.confirm_user(user)

    {:ok, account} =
      Accounts.create_account_with_owner(
        %{name: "acct-#{unique()}", slug: "acct-#{unique()}"},
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

  # A second, independent tenant so cross-account isolation tests can stage
  # rows the calling key must never reach.
  defp setup_other_account do
    {account, user} = setup_account()
    %{account: account, user: user}
  end

  defp make_runner!(account, opts) do
    name = opts[:name] || "runner-#{unique()}"

    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: name,
        external_id: opts[:external_id] || Ecto.UUID.generate(),
        group: opts[:group] || "default",
        hostname: opts[:hostname] || "host-#{unique()}",
        labels: opts[:labels] || %{},
        runner_version: opts[:runner_version] || "0.1.0"
      })
      |> Repo.insert()

    if Keyword.get(opts, :connected, true) do
      # Tracks presence from the test process → reads "online".
      {:ok, runner} = Runners.connect_runner(runner)
      runner
    else
      runner
    end
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
        first_seen_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })
      |> Repo.insert()

    action
  end

  defp attestation_for(runner) do
    %{
      "version" => "emisar-attestation-v3",
      "sig" => "deadbeef",
      "nonce" => "0123456789abcdef0123456789abcdef",
      "issued_at" => "2026-06-17T12:00:00Z",
      "targets" => [runner.external_id],
      "cert" => %{
        "ca_id" => "ca-acme",
        "key_id" => "op-1",
        "public_key" => "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664",
        "valid_from" => "2026-06-25T00:00:00Z",
        "valid_until" => "2026-06-26T00:00:00Z",
        "scope" => %{"group" => "edge", "labels" => %{"env" => "prod"}},
        "serial" => "01J0CERT0000000000000000A",
        "sig" => "cafebabe"
      }
    }
  end

  defp make_api_key!(account, user, opts \\ []) do
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

    {:ok, raw, _key} =
      ApiKeys.create_key(
        %{name: "key-#{unique()}", kind: opts[:kind] || :mcp},
        subject
      )

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

      assert by_name["db-prod-01"]["id"] == runner_a.external_id
      assert by_name["db-prod-01"]["hostname"] == "10.0.5.12"
      assert by_name["db-prod-01"]["status"] == "connected"

      assert Enum.sort(by_name["db-prod-01"]["actions"] |> Enum.map(& &1["action_id"])) ==
               ["cassandra.repair", "cassandra.status"]

      assert by_name["db-prod-02"]["actions"] |> Enum.map(& &1["action_id"]) ==
               ["cassandra.repair"]
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
               [runner_a.external_id, runner_b.external_id]

      assert shared["inputSchema"]["properties"]["runners"]["maxItems"] == 2
      assert "runners" in shared["inputSchema"]["required"]

      solo = tools_by_name["solo.action"]

      assert solo["inputSchema"]["properties"]["runners"]["items"]["enum"] ==
               [runner_a.external_id]

      assert solo["inputSchema"]["properties"]["runners"]["maxItems"] == 1
      # Single advertiser is still REQUIRED — no auto-pick, no default.
      refute Map.has_key?(solo["inputSchema"]["properties"]["runners"], "default")
      assert "runners" in solo["inputSchema"]["required"]
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
            %{
              "name" => "mode",
              "type" => "string",
              "required" => true,
              "validation" => %{"enum" => ["fast", "slow"]}
            },
            %{
              "name" => "port",
              "type" => "integer",
              "default" => 8080,
              "validation" => %{"allowed" => [80, 443, 8080]}
            },
            %{"name" => "ratio", "type" => "number", "validation" => %{"min" => 0, "max" => 1}},
            %{"name" => "verbose", "type" => "boolean", "default" => false},
            %{"name" => "window", "type" => "duration", "default" => "5m"},
            %{"name" => "tags", "type" => "string_array", "validation" => %{"max_items" => 16}},
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

      assert props["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "maxItems" => 16
             }

      assert props["ids"] == %{"type" => "array", "items" => %{"type" => "integer"}}
      # Unknown type widens to string.
      assert props["mystery"]["type"] == "string"

      assert "reason" in schema["required"]
      assert "mode" in schema["required"]
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

      {:ok, run} =
        Emisar.Runs.fetch_run_by_id(
          run_entry["run_id"] || run_entry["id"],
          Fixtures.Subjects.subject_for(user, account, role: :owner)
        )

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

      assert %{"runs" => [run_entry]} = body

      {:ok, run} =
        Emisar.Runs.fetch_run_by_id(
          run_entry["run_id"] || run_entry["id"],
          Fixtures.Subjects.subject_for(user, account, role: :owner)
        )

      refute Map.has_key?(run.args, "runner")
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
          {:ok, r} =
            Emisar.Runs.fetch_run_by_id(
              entry["run_id"] || entry["id"],
              Fixtures.Subjects.subject_for(user, account, role: :owner)
            )

          r.runner_id
        end)

      assert Enum.sort(runner_ids) == Enum.sort([runner_a.id, runner_b.id, runner_c.id])
    end

    test "no runner target + single advertiser → 400 runner_required (no auto-pick)", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{"reason" => "ad-hoc"})
        |> json_response(400)

      # Even with exactly one advertiser, emisar never auto-targets — the
      # caller must identify it. The stable id is offered so a signed retry is
      # bound to the same durable runner even if its display name changes.
      assert body["error"] == "runner_required"
      assert body["candidates"] == [runner.external_id]
    end

    test "400 when multiple runners advertise + `runners` omitted", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
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

      assert Enum.sort(body["candidates"]) ==
               Enum.sort([other.external_id, runner.external_id])
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

    test "duplicate or malformed runner targets are rejected before dispatch", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      duplicate =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => [runner.name, runner.name],
          "reason" => "do not dispatch twice"
        })
        |> json_response(400)

      assert duplicate["error"] == "duplicate_runners"

      malformed =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => [runner.name, 1],
          "reason" => "do not partially dispatch"
        })
        |> json_response(400)

      assert malformed["error"] == "invalid_runner_targets"
      assert {:ok, [], _meta} = Emisar.Runs.list_runs(subject)
    end

    test "missing reason fails fast with 400 reason_required — not a 202 of per-runner errors", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      # Explicit runner so resolution passes; the reason is what's missing.
      # The boundary rejects up front rather than fanning out N runs that each
      # error — a 202 carrying only errors would misreport "accepted".
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{"runners" => [runner.name]})
        |> json_response(400)

      assert body["error"] == "reason_required"
    end

    test "runner_not_found error includes actionable message", %{
      conn: conn,
      account: account,
      user: user
    } do
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

    test "action_not_found distinguished from no_runner_in_scope", %{
      conn: conn,
      account: account,
      user: user
    } do
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

    test "dispatch to offline runner queues + surfaces warning", %{
      conn: conn,
      account: account,
      user: user
    } do
      # Offline runner (never tracked in presence), then dispatch — should
      # still succeed (run is queued), but include warning fields so the
      # LLM can tell the user.
      runner = make_runner!(account, name: "offline-host", connected: false)
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
        Emisar.Runs.fetch_run_by_id(
          run_id,
          Fixtures.Subjects.subject_for(user, account, role: :owner)
        )

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
    setup %{account: account, user: user} do
      runner = make_runner!(account, name: "runner-1")
      raw = make_api_key!(account, user)
      {:ok, runner: runner, raw: raw}
    end

    test "returns the run state immediately when no wait param", %{
      conn: conn,
      account: account,
      runner: runner,
      raw: raw
    } do
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
      runner: runner,
      raw: raw
    } do
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
        # Delay-injection in the WRITER (finalize lands mid-wait), not
        # poll-synchronization — the long-poll itself wakes on the broadcast.
        # credo:disable-for-next-line Emisar.Checks.TestNoProcessSleep
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
      user: user,
      runner: runner,
      raw: raw
    } do
      # This is the contract the MCP bridge depends on to render
      # actionable failure output instead of "emisar status: error".
      # If any of these fields drop out of the response payload the
      # bridge's renderRunBlocks has nothing to show the LLM.
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

      # The stderr chunk streams in while the run is still live — append rejects
      # terminal runs, mirroring production where output precedes the result.
      {:ok, _} =
        Emisar.Runs.append_event(run, %{
          seq: 1,
          kind: "progress",
          stream: "stderr",
          payload: %{
            "chunk" => "nginx: bind() to 0.0.0.0:80 failed (98: Address already in use)\n"
          }
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
          finished_at: DateTime.utc_now()
        ]
      )

      {:ok, run} =
        Emisar.Runs.fetch_run_by_id(
          run.id,
          Fixtures.Subjects.subject_for(user, account, role: :owner)
        )

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
      runner: runner,
      raw: raw
    } do
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

    test "rejects an invalid wait param", %{
      conn: conn,
      account: account,
      runner: runner,
      raw: raw
    } do
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

    test "404 when fetching a run that belongs to another account", %{
      conn: conn,
      account: account,
      user: user
    } do
      other = setup_other_account()
      b_runner = make_runner!(other.account, name: "b-runner")

      {:ok, b_run} =
        Emisar.Runs.create_run(%{
          account_id: other.account.id,
          runner_id: b_runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{},
          status: "pending"
        })

      raw = make_api_key!(account, user)

      # Subject-scoped fetch_run_by_id never crosses the account boundary —
      # the foreign id is indistinguishable from a non-existent one.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{b_run.id}")
        |> json_response(404)

      assert body == %{"error" => "not_found"}
    end
  end

  describe "GET /api/mcp/runners visibility omissions" do
    test "a disabled runner is omitted from the list", %{
      conn: conn,
      account: account,
      user: user
    } do
      active = make_runner!(account, name: "active-host")
      disabled = make_runner!(account, name: "disabled-host")
      advertise_action!(active, action_id: "linux.x")
      advertise_action!(disabled, action_id: "linux.y")

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {:ok, _} = Runners.disable_runner(disabled, subject)

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)

      names = Enum.map(body["runners"], & &1["name"])
      assert "active-host" in names
      refute "disabled-host" in names
    end

    test "another account's runner is never visible", %{
      conn: conn,
      account: account,
      user: user
    } do
      mine = make_runner!(account, name: "mine-host")
      advertise_action!(mine, action_id: "linux.x")

      other = setup_other_account()
      theirs = make_runner!(other.account, name: "their-host")
      advertise_action!(theirs, action_id: "linux.y")

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)

      names = Enum.map(body["runners"], & &1["name"])
      assert names == ["mine-host"]
    end

    test "a reachable runner advertising nothing is present with actions: []", %{
      conn: conn,
      account: account,
      user: user
    } do
      _bare = make_runner!(account, name: "bare-host")
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)

      assert [%{"name" => "bare-host", "actions" => []}] = body["runners"]
    end
  end

  describe "GET /api/mcp/tools cross-account omission" do
    test "an action advertised only in another account is absent", %{
      conn: conn,
      account: account,
      user: user
    } do
      # (cross-account variant)
      mine = make_runner!(account, name: "mine-host")
      advertise_action!(mine, action_id: "mine.action")

      other = setup_other_account()
      theirs = make_runner!(other.account, name: "their-host")
      advertise_action!(theirs, action_id: "their.secret.action")

      raw = make_api_key!(account, user)

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/tools")
        |> json_response(200)
        |> Map.fetch!("tools")
        |> Enum.map(& &1["name"])

      assert "mine.action" in names
      refute "their.secret.action" in names
    end

    test "the REST /tools list omits the four synthetic tools (RPC-only)", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime")
      raw = make_api_key!(account, user)

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/tools")
        |> json_response(200)
        |> Map.fetch!("tools")
        |> Enum.map(& &1["name"])

      # The synthetic tools are appended only on the JSON-RPC tools/list path.
      assert "linux.uptime" in names
      refute "wait_for_run" in names
      refute "list_runbooks" in names
      refute "get_runbook" in names
      refute "recent_runs" in names
    end
  end

  describe "POST /api/mcp/tools/:action_id control-key handling" do
    setup %{account: account} do
      runner = make_runner!(account, name: "host-1")

      advertise_action!(runner,
        action_id: "linux.touch",
        args_schema: %{
          "args" => [%{"name" => "path", "type" => "string", "required" => true}]
        }
      )

      {:ok, runner: runner}
    end

    test "reserved control keys are stripped from the recorded action args", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.touch", %{
          "runners" => [runner.name],
          "reason" => "x",
          "wait" => "0",
          "idempotency_key" => "k-#{unique()}",
          "path" => "/tmp/marker"
        })
        |> json_response(202)

      [entry] = body["runs"]

      {:ok, run} =
        Emisar.Runs.fetch_run_by_id(
          run_id_of(entry),
          Fixtures.Subjects.subject_for(user, account, role: :owner)
        )

      # Only the genuine action arg survives — action_id/reason/runners/wait/
      # idempotency_key are all dropped before the runner sees the args.
      assert run.args == %{"path" => "/tmp/marker"}
      refute Map.has_key?(run.args, "idempotency_key")
      refute Map.has_key?(run.args, "reason")
      refute Map.has_key?(run.args, "runners")
      refute Map.has_key?(run.args, "wait")
    end

    test "relays a valid attestation as a control envelope, not an action arg", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      attestation = attestation_for(runner)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.touch", %{
          "runners" => [runner.external_id],
          "reason" => "x",
          "wait" => "0",
          "path" => "/tmp/marker",
          "attestation" => attestation
        })
        |> json_response(202)

      [entry] = body["runs"]

      {:ok, run} =
        Emisar.Runs.fetch_run_by_id(
          run_id_of(entry),
          Fixtures.Subjects.subject_for(user, account, role: :owner)
        )

      assert run.attestation == attestation
      refute Map.has_key?(run.args, "attestation")
      assert run.args["path"] == "/tmp/marker"
    end

    test "an exact stable id wins over another runner's colliding display name", %{
      conn: conn,
      account: account,
      user: user
    } do
      target_id = Ecto.UUID.generate()
      target = make_runner!(account, name: "zz-exact-id", external_id: target_id)
      display_collision = make_runner!(account, name: target_id)
      advertise_action!(target, action_id: "linux.touch")
      advertise_action!(display_collision, action_id: "linux.touch")
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.touch", %{
          "runners" => [target_id],
          "reason" => "verify stable target precedence",
          "wait" => "0",
          "path" => "/tmp/marker",
          "attestation" => attestation_for(target)
        })
        |> json_response(202)

      [entry] = body["runs"]
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      assert {:ok, run} = Emisar.Runs.fetch_run_by_id(run_id_of(entry), subject)
      assert run.runner_id == target.id
    end

    test "rejects a malformed supplied attestation without creating a run", %{
      conn: conn,
      account: account,
      user: user,
      runner: runner
    } do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.touch", %{
          "runners" => [runner.external_id],
          "reason" => "x",
          "wait" => "0",
          "path" => "/tmp/marker",
          "attestation" => %{"sig" => "incomplete"}
        })
        |> json_response(400)

      assert body["error"] == "invalid_attestation"

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      assert {:ok, [], _meta} = Emisar.Runs.list_runs(subject)
    end
  end

  describe "GET /api/mcp/runs/:id state edges" do
    setup %{account: account, user: user} do
      raw = make_api_key!(account, user)
      {:ok, raw: raw}
    end

    test "an unknown run id is a 404 not_found", %{conn: conn, raw: raw} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{Ecto.UUID.generate()}")
        |> json_response(404)

      assert body == %{"error" => "not_found"}
    end

    test "a non-terminal run with no wait param returns 200 (not 202)", %{
      conn: conn,
      account: account,
      raw: raw
    } do
      runner = make_runner!(account, name: "runner-1")

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "running"
        })

      # No `?wait=` → current state at 200, even though it's not terminal.
      # The 202 "still waiting" envelope is reserved for a real long-poll.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}")
        |> json_response(200)

      assert body["status"] == "running"
      refute Map.has_key?(body, "waiting")
    end
  end

  describe "GET /api/mcp/runs/:id full payload shape" do
    test "stdout over 64 KiB is tail-truncated + flagged, with full hash + byte count", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "chatty-host")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.cat",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "pending"
        })

      # Emit > 64 KiB of stdout across the run's events. The payload caps the
      # rendered stdout at 65_536 bytes (tail), so the END must survive and the
      # head must be dropped — that's what the cap keeps for a `tail -f`-style read.
      # The HEAD marker sits in the first 100 KiB, comfortably outside the 64 KiB
      # tail window, so its absence proves the head was discarded (not just resized).
      head = "HEAD-MARKER-DROPPED" <> String.duplicate("A", 100_000)
      tail = "THE-VERY-END-OF-OUTPUT"
      full_stdout = head <> tail
      total_bytes = byte_size(full_stdout)

      {:ok, _} =
        Emisar.Runs.append_event(run, %{
          seq: 1,
          kind: "progress",
          stream: "stdout",
          payload: %{"chunk" => full_stdout}
        })

      # The runner reports the authoritative hash + byte count over the COMPLETE
      # stream; finalize stores them on the row (set directly here).
      digest = :crypto.hash(:sha256, full_stdout) |> Base.encode16(case: :lower)

      Repo.update_all(
        from(r in Emisar.Runs.ActionRun, where: r.id == ^run.id),
        set: [
          status: "success",
          exit_code: 0,
          stdout_sha256: digest,
          stdout_bytes: total_bytes,
          finished_at: DateTime.utc_now()
        ]
      )

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}")
        |> json_response(200)

      # Tail kept, head dropped, and the truncation is flagged.
      assert body["stdout_truncated"] == true
      assert byte_size(body["stdout"]) == 65_536
      assert String.ends_with?(body["stdout"], tail)
      refute body["stdout"] =~ "HEAD-MARKER-DROPPED"

      # Hash + byte count are the FULL values (cover the whole stream, not the tail).
      assert body["stdout_sha256"] == digest
      assert body["stdout_bytes"] == total_bytes
      assert total_bytes > 65_536
    end

    test "output preview reads only the most recent bounded event tail", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "event-tail-host")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.cat",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "pending"
        })

      for seq <- 1..33 do
        {:ok, _} =
          Emisar.Runs.append_event(run, %{
            seq: seq,
            kind: "progress",
            stream: "stdout",
            payload: %{"chunk" => "line-#{seq}\\n"}
          })
      end

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}")
        |> json_response(200)

      assert body["output_events_truncated"] == true
      assert body["stdout"] =~ "line-2"
      assert body["stdout"] =~ "line-33"
      refute body["stdout"] =~ "line-1\\n"
      assert body["stdout_truncated"] == false
    end

    test "the policy block carries decision, reason, and matched rules", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "policy-host")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "success",
          policy_decision: "require_approval",
          policy_reason: "high-risk tier requires approval",
          matched_rules: ["default:high", "override:after-hours"]
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}")
        |> json_response(200)

      assert body["policy"] == %{
               "decision" => "require_approval",
               "reason" => "high-risk tier requires approval",
               "rules" => ["default:high", "override:after-hours"]
             }
    end
  end

  describe "POST /api/mcp/tools/:action_id pending-approval payload variant" do
    test "a require-approval dispatch returns waiting_on:approval + policy + a wait tip", %{
      conn: conn,
      account: account,
      user: user
    } do
      runner = make_runner!(account, name: "approval-host")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      # Flip the account policy so the dispatch parks for human approval.
      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "require_approval",
              "medium" => "require_approval",
              "high" => "require_approval",
              "critical" => "require_approval"
            },
            "overrides" => []
          },
          subject
        )

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/api/mcp/tools/linux.uptime", %{
          "runners" => [runner.name],
          "reason" => "smoke"
        })
        |> json_response(202)

      assert [entry] = body["runs"]
      # The pending variant is distinct from a terminal/in-flight payload: it
      # names the approval wait + carries the policy decision + a wait_for_run tip.
      assert entry["status"] == "pending_approval"
      assert entry["waiting_on"] == "approval"
      assert is_binary(entry["run_id"])
      assert is_map(entry["policy"])
      assert entry["tip"] =~ "wait_for_run"
    end
  end

  describe "GET /api/mcp/runners scope + visibility model" do
    test "an unrestricted key (no filter, no creator scope) sees every account runner", %{
      conn: conn,
      account: account,
      user: user
    } do
      # A default-minted key's creator membership holds no per-user runner-scope
      # grants, so the creator-scope layer narrows nothing: all account runners show.
      a = make_runner!(account, name: "host-a", group: "g1")
      b = make_runner!(account, name: "host-b", group: "g2")
      c = make_runner!(account, name: "host-c", group: "g3")
      for r <- [a, b, c], do: advertise_action!(r, action_id: "linux.uptime")

      raw = make_api_key!(account, user)

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)
        |> Map.fetch!("runners")
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      assert names == ["host-a", "host-b", "host-c"]
    end
  end

  describe "GET /api/mcp/runners wire status vocabulary" do
    test "status uses the connected / disconnected / pending vocabulary", %{
      conn: conn,
      account: account,
      user: user
    } do
      # Three reachable connection states map to the pre-presence wire words MCP
      # clients expect. (`disabled` is omitted from /runners entirely — covered
      # by — so it can't appear here.)
      _online = make_runner!(account, name: "online-host")

      # Offline = was connected once but isn't tracked in Presence now. Create it
      # OUT of presence (connected: false) and stamp last_connected_at so
      # connection_state resolves :offline (not :pending) → wire "disconnected".
      gone = make_runner!(account, name: "gone-host", connected: false)

      {1, _} =
        Repo.update_all(
          from(r in Runner, where: r.id == ^gone.id),
          set: [last_connected_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
        )

      _never = make_runner!(account, name: "never-host", connected: false)

      raw = make_api_key!(account, user)

      by_name =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)
        |> Map.fetch!("runners")
        |> Map.new(&{&1["name"], &1["status"]})

      assert by_name["online-host"] == "connected"
      assert by_name["gone-host"] == "disconnected"
      assert by_name["never-host"] == "pending"
      # The wire word is always one of the documented four.
      assert Map.values(by_name) -- ~w(connected disconnected disabled pending) == []
    end
  end

  describe "long-poll wait caps (REST)" do
    test "dispatch ?wait is capped at 60s; /runs/:id ?wait at five minutes", %{
      conn: conn,
      account: account,
      user: user
    } do
      # The two REST long-poll budgets differ by endpoint and are both enforced via
      # parse_wait's clamp, even when a client asks for a larger duration.
      # Assert the clamp CONSTANTS (no sleeping):
      #   - dispatch (POST /tools/:id) uses max_wait_ms (60s),
      #   - get_run (GET /runs/:id) uses max_get_run_wait_ms (five minutes).
      assert Service.parse_wait("5m", Service.max_wait_ms()) == {:ok, 60_000}
      assert Service.parse_wait("600s", Service.max_get_run_wait_ms()) == {:ok, 300_000}

      # And the get_run endpoint ACCEPTS an over-cap ?wait rather than rejecting it
      # as invalid_wait — the clamp is silent. A terminal run returns 200 (the cap
      # only bounds how long a non-terminal run would block; a finished one returns
      # at once).
      runner = make_runner!(account, name: "cap-host")
      raw = make_api_key!(account, user)

      {:ok, run} =
        Emisar.Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: pick_key(account, raw).id,
          args: %{},
          status: "success"
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runs/#{run.id}?wait=600s")
        |> json_response(200)

      assert body["status"] == "success"
      refute body["error"] == "invalid_wait"
    end
  end

  describe "creator per-user scope layer (REST)" do
    test "revoking the creator's scope shrinks every key that membership minted", %{
      conn: conn,
      account: account,
      user: user
    } do
      # Mint the key first (unrestricted membership → sees both), then narrow the
      # creator's scope and re-list on the SAME key: it loses the now-out-of-scope
      # runner. The scope is resolved per-request via created_by_membership_id, so
      # the live grant set gates the key — no re-mint needed.
      a = make_runner!(account, name: "scope-a", group: "team-a")
      b = make_runner!(account, name: "scope-b", group: "team-b")
      advertise_action!(a, action_id: "linux.x")
      advertise_action!(b, action_id: "linux.y")

      raw = make_api_key!(account, user)

      list = fn ->
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/api/mcp/runners")
        |> json_response(200)
        |> Map.fetch!("runners")
        |> Enum.map(& &1["name"])
        |> Enum.sort()
      end

      # Unrestricted: both visible.
      assert list.() == ["scope-a", "scope-b"]

      # Narrow the creator membership to team-a only — the same key now sees one.
      restrict_creator_scope!(account, user, [{"group", "team-a"}])
      assert list.() == ["scope-a"]
    end
  end

  describe "cross-account never visible across the scope model (REST)" do
    test "a foreign tenant's runner + action are absent from /runners and /tools", %{
      conn: conn,
      account: account,
      user: user
    } do
      # The outermost gate is the Subject's account (IL-4): regardless of key
      # filter or creator scope, another tenant's inventory is never reachable.
      mine = make_runner!(account, name: "mine-host")
      advertise_action!(mine, action_id: "mine.action")

      other = setup_other_account()
      theirs = make_runner!(other.account, name: "their-host")
      advertise_action!(theirs, action_id: "their.action")

      raw = make_api_key!(account, user)
      auth = &put_req_header(&1, "authorization", "Bearer " <> raw)

      runners =
        conn
        |> auth.()
        |> get(~p"/api/mcp/runners")
        |> json_response(200)
        |> Map.fetch!("runners")

      assert Enum.map(runners, & &1["name"]) == ["mine-host"]

      tools =
        conn |> auth.() |> get(~p"/api/mcp/tools") |> json_response(200) |> Map.fetch!("tools")

      tool_names = Enum.map(tools, & &1["name"])
      assert "mine.action" in tool_names
      refute "their.action" in tool_names
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

  # Narrow the key-creator's membership to the given scopes (string tuples, e.g.
  # [{"group", "allowed"}]) so the per-user scope layer gates every key it minted.
  defp restrict_creator_scope!(account, user, scopes) do
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    {:ok, :ok} = Runners.replace_runner_scopes(membership, scopes, subject)
    :ok
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
