defmodule EmisarWeb.MCPRpcControllerTest do
  @moduledoc """
  Covers POST /api/mcp/rpc — the MCP-over-HTTP / JSON-RPC endpoint.
  Same Bearer-token auth as the REST surface; same Service module
  under the hood. Tests focus on the JSON-RPC envelope, the synthetic
  wait_for_run tool, and MCP content-block rendering.
  """

  use EmisarWeb.ConnCase, async: true
  import Ecto.Query
  alias Emisar.{Accounts, ApiKeys, Policies, Repo, Runners, Runs, Users}
  alias Emisar.Accounts.Account
  alias Emisar.Catalog.RunnerAction
  alias Emisar.Runners.Runner
  alias EmisarWeb.MCP.Service
  alias EmisarWeb.Plugs.RateLimit

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
        side_effects: opts[:side_effects] || [],
        args_schema: opts[:args_schema] || %{"args" => []},
        first_seen_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })
      |> Repo.insert()

    action
  end

  defp make_api_key!(account, user, opts \\ []) do
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

    {:ok, raw, _key} =
      ApiKeys.create_key(
        %{
          name: "key-#{unique()}",
          scopes: opts[:scopes] || ["actions:read", "actions:execute"],
          action_scope: opts[:action_scope] || [],
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

  describe "auth edge cases" do
    # The auth plug only matches `["Bearer " <> raw]`; a longer-than-prefix
    # bogus emk- secret runs the real hash-miss lookup (peek_api_key_by_secret
    # → nil), distinct from the too-short fast path. Every failure shape lands
    # on the same JSON-RPC -32001 envelope + the RFC 9728 challenge header.
    test "a hash-miss emk- secret is unauthorized", %{conn: conn} do
      bogus = "emk-" <> String.duplicate("0", 40)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> bogus)
        |> rpc("initialize")

      assert %{"error" => %{"code" => -32001}} = json_response(conn, 401)
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "resource_metadata="
    end

    test "a revoked emk- key is unauthorized", %{conn: conn, account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {:ok, raw, key} = ApiKeys.create_key(%{name: "to-revoke-#{unique()}"}, subject)
      {:ok, _} = ApiKeys.revoke_api_key(key, subject)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("initialize")
        |> json_response(401)

      assert body["error"]["code"] == -32001
    end

    test "a literal `Bearer` with no token is unauthorized", %{conn: conn} do
      body =
        conn
        # No trailing space/token — never the `"Bearer " <> raw` shape.
        |> put_req_header("authorization", "Bearer")
        |> rpc("initialize")
        |> json_response(401)

      assert body["error"]["code"] == -32001
    end

    test "an empty `Bearer ` token is unauthorized", %{conn: conn} do
      body =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> rpc("initialize")
        |> json_response(401)

      assert body["error"]["code"] == -32001
    end

    test "a non-Bearer scheme (Basic / Token) is unauthorized",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      for scheme <- ["Basic " <> raw, "Token " <> raw, "bearer " <> raw] do
        body =
          conn
          |> put_req_header("authorization", scheme)
          |> rpc("initialize")
          |> json_response(401)

        assert body["error"]["code"] == -32001, "expected 401 for scheme #{inspect(scheme)}"
      end
    end

    test "a key for a soft-deleted account is unauthorized",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      # The key still resolves, but fetch_account_by_id uses not_deleted() —
      # a tombstoned account makes the bearer unresolvable.
      Repo.update_all(
        from(a in Account, where: a.id == ^account.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("initialize")
        |> json_response(401)

      assert body["error"]["code"] == -32001
    end

    test "every 401 carries the RFC 9728 WWW-Authenticate challenge",
         %{conn: conn} do
      # The challenge points an unauthenticated MCP client at the protected-
      # resource metadata so it can discover the AS and start the OAuth flow.
      # MCP.Auth sets it on the conn for ANY resolve failure — assert it's
      # present and well-formed on a bog-standard missing-bearer 401.
      conn = rpc(conn, "initialize")

      assert %{"error" => %{"code" => -32001}} = json_response(conn, 401)
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~r/^Bearer resource_metadata="https?:\/\//
      assert challenge =~ "/.well-known/oauth-protected-resource"
    end
  end

  describe "OAuth (emo-) token edges" do
    test "emk- and emo- dispatch with identical attribution (no path branches on bearer kind)",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      subject = subject_for(account, user)

      # NOTE (spec premise corrected): the emo- OAuth flow MINTS ITS OWN backing
      # key (OAuth.issue_code → create_backing_key), so an emo- token never backs
      # onto a pre-existing emk- key — they're DISTINCT api_keys rows by design.
      # The real, code-guaranteed invariant is narrower and is what we assert:
      # both bearer kinds resolve through one auth path and dispatch with identical
      # ATTRIBUTION SHAPE (same source, same execute scope, same account) — nothing
      # downstream branches on emk- vs emo-. The only difference is the key row id.
      {:ok, emk, emk_key} =
        ApiKeys.create_key(
          %{name: "static-#{unique()}", scopes: ["actions:read", "actions:execute"]},
          subject
        )

      {emo, _emo_key} = mint_oauth_token!(account, user)

      dispatch = fn bearer ->
        conn
        |> put_req_header("authorization", "Bearer " <> bearer)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "dual-bearer", "wait" => "0"}
        })
        |> json_response(200)
      end

      assert dispatch.(emk)["result"]["isError"] == false
      assert dispatch.(emo)["result"]["isError"] == false

      {:ok, runs, _meta} = Runs.list_runs(subject)
      assert length(runs) == 2

      # Identical attribution shape across both bearers: same source + same
      # account; each carries a real (non-nil) backing key id. The api_key_id
      # rows differ (emo- has its own minted key) — that's the by-design seam.
      # `source` is an Ecto.Enum → loads as the atom :mcp (IL: compare atoms).
      assert Enum.map(runs, & &1.source) == [:mcp, :mcp]
      assert runs |> Enum.map(& &1.account_id) |> Enum.uniq() == [account.id]
      assert Enum.all?(runs, &is_binary(&1.api_key_id))

      # The emo- token's minted key is execute-capable — consent grants the same
      # scope set as the manual key, so the dispatch wasn't a read-only fluke.
      [emk_id] = [emk_key.id]
      emo_run = Enum.find(runs, &(&1.api_key_id != emk_id))
      {:ok, emo_key} = ApiKeys.fetch_api_key_by_id(emo_run.api_key_id, subject)
      assert "actions:execute" in emo_key.scopes
    end

    test "an expired emo- token is unauthorized",
         %{conn: conn, account: account, user: user} do
      {emo, key} = mint_oauth_token!(account, user)

      # Push access_expires_at into the past — resolve_access_token's
      # `live?(access_expires_at)` gate then fails → {:error, :invalid} → 401.
      Repo.update_all(
        from(t in Emisar.OAuth.Token, where: t.api_key_id == ^key.id),
        set: [access_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> emo)
        |> rpc("initialize")
        |> json_response(401)

      assert body["error"]["code"] == -32001
    end

    test "an emo- token whose backing key was revoked is unauthorized",
         %{conn: conn, account: account, user: user} do
      subject = subject_for(account, user)
      {emo, key} = mint_oauth_token!(account, user)

      # The token row stays live, but its backing key is revoked — resolve_access_token
      # then loads the key via peek_api_key_by_id, which returns nil for a non-usable
      # (revoked) key → the bearer is unresolvable → 401.
      {:ok, _} = ApiKeys.revoke_api_key(key, subject)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> emo)
        |> rpc("initialize")
        |> json_response(401)

      assert body["error"]["code"] == -32001
    end
  end

  describe "scope guard edge (NULL scopes)" do
    test "the scopes column is NOT NULL — the NULL precondition can't exist",
         %{account: account, user: user} do
      # The spec row posits a key row with NULL scopes reaching the
      # `key.scopes || []` guard. That precondition is UNREACHABLE: the DB
      # enforces NOT NULL on api_keys.scopes (column default []), so a NULL can
      # never be persisted — the `|| []` in require_scope is dead-but-defensive.
      # We pin the actual guarantee: the constraint rejects a NULL write, so the
      # only reachable fail-closed path is the empty-array case.
      subject = subject_for(account, user)
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "null-scopes-#{unique()}"}, subject)

      assert_raise Postgrex.Error, ~r/not_null|null value/, fn ->
        Repo.update_all(
          from(k in Emisar.ApiKeys.ApiKey, where: k.id == ^key.id),
          set: [scopes: nil]
        )
      end
    end
  end

  describe "ping scope + auth" do
    test "ping works with a read-only key (no scope check on ping)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("ping", %{}, 7)
        |> json_response(200)

      assert body == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
    end

    test "an unauthenticated ping is 401 (the auth plug runs first)", %{conn: conn} do
      body =
        conn
        |> rpc("ping", %{}, 7)
        |> json_response(401)

      # No bearer never reaches the (ungated) ping handler — the plug halts first.
      assert body["error"]["code"] == -32001
    end
  end

  describe "notifications (silent drop)" do
    setup %{account: account, user: user} do
      {:ok, raw: make_api_key!(account, user)}
    end

    test "an unknown notification name is still a 202 silent drop (not -32601)",
         %{conn: conn, raw: raw} do
      # The prefix match on "notifications/" wins over the unknown-method clause,
      # so a never-heard-of notification is dropped, never a method-not-found error.
      payload = %{jsonrpc: "2.0", method: "notifications/whatever_unknown"}

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/mcp/rpc", Jason.encode!(payload))
      |> response(202)
    end

    test "a notification carrying an id is still dropped (prefix match wins)",
         %{conn: conn, raw: raw} do
      # An id on a notifications/* frame doesn't promote it to a request — the
      # method prefix decides, so it's a no-reply 202 with an empty body.
      payload = %{jsonrpc: "2.0", id: 99, method: "notifications/initialized"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(payload))

      assert response(conn, 202) == ""
    end
  end

  describe "rate limiting" do
    # A full 300-call flood is impractical in the fast suite (the limiter is
    # disabled suite-wide so shared counters don't make tests flaky). The plug
    # mechanics live in rate_limit_test.exs; here we exercise the same config
    # the MCP controllers wire — the per-bearer "mcp"-style bucket — to pin the
    # over-limit boundary + per-bearer grain that protects the MCP surface.
    test "over the limit returns 429 + Retry-After, keyed per bearer", %{conn: conn} do
      previous = Application.get_env(:emisar_web, :rate_limit_enabled, true)
      Application.put_env(:emisar_web, :rate_limit_enabled, true)
      on_exit(fn -> Application.put_env(:emisar_web, :rate_limit_enabled, previous) end)

      bucket = "mcp-test-#{unique()}"
      opts = RateLimit.init(bucket: bucket, limit: 2, window_ms: 60_000, by: :bearer)

      key_a = put_req_header(conn, "authorization", "Bearer emk-aaaa")
      key_b = put_req_header(conn, "authorization", "Bearer emk-bbbb")

      assert %{halted: false} = RateLimit.call(key_a, opts)
      assert %{halted: false} = RateLimit.call(key_a, opts)

      over = RateLimit.call(key_a, opts)
      assert over.halted
      assert over.status == 429
      assert get_resp_header(over, "retry-after") == ["60"]
      assert over.resp_body =~ "rate_limited"

      # A different bearer is a different bucket — its own budget is intact,
      # so the cap is per-key, not per-IP (both share the conn's IP here).
      assert %{halted: false} = RateLimit.call(key_b, opts)
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
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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

    test "initialize is NOT scope-gated — both read-only and execute-only keys handshake",
         %{conn: conn, account: account, user: user} do
      # The handshake precedes capability negotiation, so it carries no scope
      # gate (only the auth plug). A key of EITHER single scope completes it.
      for scopes <- [["actions:read"], ["actions:execute"]] do
        raw = make_api_key!(account, user, scopes: scopes)

        body =
          conn
          |> put_req_header("authorization", "Bearer " <> raw)
          |> rpc("initialize")
          |> json_response(200)

        assert body["result"]["protocolVersion"] == "2024-11-05"
        refute Map.has_key?(body, "error")
      end
    end

    test "initialize still requires a valid bearer (auth plug runs first)", %{conn: conn} do
      body = conn |> rpc("initialize") |> json_response(401)
      assert body["error"]["code"] == -32001
    end

    test "a blank client-sent Mcp-Session-Id is replaced with a freshly minted one",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        # An empty header value fails the non-empty check, so the server mints one.
        |> put_req_header("mcp-session-id", "")
        |> rpc("initialize")

      assert [minted] = get_resp_header(conn, "mcp-session-id")
      assert minted != ""
      # A minted id is a UUID (not the blank the client sent back).
      assert {:ok, _} = Ecto.UUID.cast(minted)
    end

    test "initialize with no clientInfo records nothing and still handshakes",
         %{conn: conn, account: account, user: user} do
      subject = subject_for(account, user)
      {:ok, raw, key} = ApiKeys.create_key(%{name: "no-ci-#{unique()}"}, subject)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        # No clientInfo key at all → sanitize returns nil → nothing recorded.
        |> rpc("initialize")
        |> json_response(200)

      assert body["result"]["protocolVersion"] == "2024-11-05"
      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert reloaded.last_client_info == %{}
    end
  end

  describe "initialize — response-carried rotation" do
    test "a bridge client with an expiring key gets a one-shot successor in headers",
         %{conn: conn, account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      soon = DateTime.add(DateTime.utc_now(), 3, :day)

      {:ok, raw, _key} =
        ApiKeys.create_key(%{name: "bridge-#{unique()}", expires_at: soon}, subject)

      first =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("user-agent", "emisar-mcp/9.9 (client=test; host=h; os=darwin)")
        |> rpc("initialize")

      assert %{"result" => _} = json_response(first, 200)
      assert [successor_raw] = get_resp_header(first, "x-emisar-successor-key")
      assert String.starts_with?(successor_raw, "emk-")
      assert [expires] = get_resp_header(first, "x-emisar-successor-expires-at")
      assert {:ok, _expiry, _offset} = DateTime.from_iso8601(expires)

      # The successor authenticates immediately (the header is live).
      pong =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> successor_raw)
        |> rpc("ping")

      assert %{"result" => %{}} = json_response(pong, 200)

      # At most once — the superseded key's next initialize offers nothing.
      second =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("user-agent", "emisar-mcp/9.9 (client=test; host=h; os=darwin)")
        |> rpc("initialize")

      assert %{"result" => _} = json_response(second, 200)
      assert get_resp_header(second, "x-emisar-successor-key") == []
    end

    test "no successor for a non-bridge client or a far-from-expiry key",
         %{conn: conn, account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      soon = DateTime.add(DateTime.utc_now(), 3, :day)
      far = DateTime.add(DateTime.utc_now(), 30, :day)

      {:ok, expiring_raw, _key} =
        ApiKeys.create_key(%{name: "close-#{unique()}", expires_at: soon}, subject)

      {:ok, far_raw, _key} =
        ApiKeys.create_key(%{name: "far-#{unique()}", expires_at: far}, subject)

      far_conn =
        conn
        |> put_req_header("authorization", "Bearer " <> far_raw)
        |> put_req_header("user-agent", "emisar-mcp/9.9 (client=test; host=h; os=darwin)")
        |> rpc("initialize")

      assert %{"result" => _} = json_response(far_conn, 200)
      assert get_resp_header(far_conn, "x-emisar-successor-key") == []

      # A remote connector ignores response headers — don't burn the one-shot
      # successor on it.
      remote =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> expiring_raw)
        |> put_req_header("user-agent", "Mozilla/5.0 (claude.ai connector)")
        |> rpc("initialize")

      assert %{"result" => _} = json_response(remote, 200)
      assert get_resp_header(remote, "x-emisar-successor-key") == []
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

    test "action_scope refuses an out-of-scope action with isError, dispatching nothing",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      advertise_action!(runner, action_id: "linux.reboot", risk: "critical")
      raw = make_api_key!(account, user, action_scope: ["linux.uptime"])
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.reboot",
          "arguments" => %{"runner" => "host-1", "reason" => "should be blocked", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "action scope"
      # The refusal is at the dispatch boundary, before any run is created.
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "records the Mcp-Session-Id header on the dispatched run",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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

    test "extracts a well-formed attestation (nested cert) and stores it on the run, not in the args",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      attestation = %{
        "sig" => "deadbeef",
        "nonce" => "n1",
        "issued_at" => "2026-06-17T12:00:00Z",
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

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        "arguments" => %{
          "runner" => "host-1",
          "reason" => "smoke",
          "wait" => "0",
          "attestation" => attestation
        }
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert run.attestation == attestation
      # The attestation is a control key, not an action argument — it must not
      # leak into the args the runner validates and signs over.
      refute Map.has_key?(run.args, "attestation")
    end

    test "a malformed attestation is dropped to nil (enforcing runner then refuses)",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        # The cert is missing required fields — not a well-formed envelope, so the
        # whole attestation degrades to nil and an enforcing runner refuses.
        "arguments" => %{
          "runner" => "host-1",
          "reason" => "smoke",
          "wait" => "0",
          "attestation" => %{
            "sig" => "x",
            "nonce" => "n1",
            "issued_at" => "2026-06-17T12:00:00Z",
            "cert" => %{"ca_id" => "ca-acme", "sig" => "cafe"}
          }
        }
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert run.attestation == nil
      refute Map.has_key?(run.args, "attestation")
    end

    test "an oversized cert field is rejected (dropped to nil)",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        # A 9 KB public_key inside the cert — far over the 512-byte field cap, the
        # multi-MB-blob abuse a key-blind relay must still bound.
        "arguments" => %{
          "runner" => "host-1",
          "reason" => "smoke",
          "wait" => "0",
          "attestation" => %{
            "sig" => "deadbeef",
            "nonce" => "n1",
            "issued_at" => "2026-06-17T12:00:00Z",
            "cert" => %{
              "ca_id" => "ca-acme",
              "key_id" => "op-1",
              "public_key" => String.duplicate("a", 9_000),
              "valid_from" => "2026-06-25T00:00:00Z",
              "valid_until" => "2026-06-26T00:00:00Z",
              "scope" => %{},
              "serial" => "01J0CERT0000000000000000A",
              "sig" => "cafebabe"
            }
          }
        }
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert run.attestation == nil
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
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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
    setup %{account: account, user: user} do
      {:ok, raw: make_api_key!(account, user)}
    end

    test "missing run_id is an in-band tool error", %{conn: conn, raw: raw} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "wait_for_run", "arguments" => %{}})

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "requires `run_id`"
    end

    test "an unparseable timeout is an in-band tool error", %{conn: conn, raw: raw} do
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

    test "an unknown run id reads as not found", %{conn: conn, raw: raw} do
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
      raw: raw
    } do
      runner = make_runner!(account, [])

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
      raw: raw
    } do
      runner = make_runner!(account, [])

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
    setup %{account: account, user: user} do
      {:ok, raw: make_api_key!(account, user)}
    end

    test "missing runbook arg is an in-band tool error", %{conn: conn, raw: raw} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "get_runbook", "arguments" => %{}})

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "requires `runbook`"
    end

    test "an unknown slug reads as not found", %{conn: conn, raw: raw} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "get_runbook", "arguments" => %{"runbook" => "ghost"}})

      body = json_response(conn, 200)
      assert get_in(body, ["result", "isError"]) == true
      assert content_text(body) =~ "Runbook not found"
    end
  end

  describe "reason gate (RPC dispatch path)" do
    setup %{account: account} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      {:ok, runner: runner}
    end

    test "a whitespace-only reason is rejected with reason_required",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "   ", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Reason required"
    end

    test "a non-string reason is rejected with reason_required",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => 123, "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Reason required"
    end

    test "a reason-denied dispatch leaves no orphan run row",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        # Reason gated at the context layer (require_reason) BEFORE the run
        # row is created — a missing reason must not leave a dangling run.
        "arguments" => %{"runner" => "host-1", "wait" => "0"}
      })
      |> json_response(200)

      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end
  end

  describe "cross-account isolation" do
    test "a key cannot tools/call an action that exists only in another account",
         %{conn: conn, account: account, user: user} do
      other = setup_other_account()
      make_runner!(other.account, name: "b-host") |> advertise_action!(action_id: "b.only.action")

      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "b.only.action",
          "arguments" => %{"reason" => "smoke", "wait" => "0"}
        })
        |> json_response(200)

      # Subject-scoped catalog never sees account B's action, so it reads as
      # an unknown action — never dispatched, never leaked as "exists elsewhere".
      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Action not found"
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "wait_for_run on a foreign-account run id reads as not found",
         %{conn: conn, account: account, user: user} do
      other = setup_other_account()
      b_runner = make_runner!(other.account, name: "b-host")

      {:ok, b_run} =
        Runs.create_run(%{
          account_id: other.account.id,
          runner_id: b_runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{}
        })

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => b_run.id, "timeout" => ""}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Run not found"
    end

    test "recent_runs scope:account never returns another account's runs",
         %{conn: conn, account: account, user: user} do
      other = setup_other_account()
      b_runner = make_runner!(other.account, name: "b-host")

      {:ok, b_run} =
        Runs.create_run(%{
          account_id: other.account.id,
          runner_id: b_runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          args: %{}
        })

      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"scope" => "account"}})
        |> json_response(200)

      assert body["result"]["isError"] == false
      # for_subject scopes to account A even at scope=account — B's run is invisible.
      refute content_text(body) =~ b_run.id
    end
  end

  describe "scope denial matrix (read verbs)" do
    test "an execute-only key is denied list_runbooks (needs actions:read)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:execute"])

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:read"}}} =
               conn
               |> put_req_header("authorization", "Bearer " <> raw)
               |> rpc("tools/call", %{"name" => "list_runbooks", "arguments" => %{}})
               |> json_response(200)
    end

    test "an execute-only key is denied get_runbook (needs actions:read)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:execute"])

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:read"}}} =
               conn
               |> put_req_header("authorization", "Bearer " <> raw)
               |> rpc("tools/call", %{
                 "name" => "get_runbook",
                 "arguments" => %{"runbook" => "anything"}
               })
               |> json_response(200)
    end

    test "an empty scopes:[] key fails closed on every gated verb",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: [])

      for {name, args, required} <- [
            {"linux.uptime", %{"reason" => "x"}, "actions:execute"},
            {"list_runbooks", %{}, "actions:read"},
            {"recent_runs", %{}, "actions:read"}
          ] do
        body =
          conn
          |> put_req_header("authorization", "Bearer " <> raw)
          |> rpc("tools/call", %{"name" => name, "arguments" => args})
          |> json_response(200)

        assert body["error"]["code"] == -32002,
               "expected scope denial for #{name}, got #{inspect(body)}"

        assert body["error"]["data"]["required"] == required
      end

      # tools/list is read-gated too — empty scopes can't even discover.
      list =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)

      assert list["error"]["data"]["required"] == "actions:read"
    end
  end

  describe "tools/list ordering" do
    test "tools are sorted alphabetically by name", %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      # Advertise out of alphabetical order so a non-sorting impl would leak it.
      advertise_action!(runner, action_id: "zzz.last", title: "Z")
      advertise_action!(runner, action_id: "aaa.first", title: "A")
      advertise_action!(runner, action_id: "mmm.middle", title: "M")
      raw = make_api_key!(account, user)

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])

      # The three real action tools precede the synthetic ones and are sorted.
      action_names = Enum.take(names, 3)
      assert action_names == ["aaa.first", "mmm.middle", "zzz.last"]
    end
  end

  describe "runner fan-out boundary (exactly 16 vs 17)" do
    test "exactly 16 runners dispatches all 16 (the cap is inclusive)",
         %{conn: conn, account: account, user: user} do
      names = for i <- 1..16, do: "fan-#{i}"

      for name <- names do
        account
        |> make_runner!(name: name)
        |> advertise_action!(action_id: "linux.uptime", risk: "low")
      end

      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runners" => names, "reason" => "fan-out", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == false
      # One run row per runner — the whole fan-out went through.
      {:ok, runs, _meta} = Runs.list_runs(subject)
      assert length(runs) == 16
    end

    test "17 runners is rejected with too_many_runners and creates no runs",
         %{conn: conn, account: account, user: user} do
      names = for i <- 1..17, do: "fan-#{i}"

      for name <- names do
        account
        |> make_runner!(name: name)
        |> advertise_action!(action_id: "linux.uptime", risk: "low")
      end

      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runners" => names, "reason" => "fan-out", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Too many runners"
      # Resolution failed before any dispatch — no orphan rows.
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end
  end

  describe "recent_runs limit validation" do
    setup %{account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])
      {:ok, raw: raw}
    end

    test "a non-numeric limit is rejected, not silently coerced",
         %{conn: conn, raw: raw} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"limit" => "abc"}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "limit"
    end

    test "limit 0 is rejected (non-positive)", %{conn: conn, raw: raw} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"limit" => 0}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "limit"
    end

    test "limit -1 is rejected (non-positive)", %{conn: conn, raw: raw} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"limit" => -1}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "limit"
    end

    test "a limit above 100 is clamped, not rejected", %{conn: conn, raw: raw} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"limit" => 1000}})
        |> json_response(200)

      # 1000 → min(1000, 100) = 100; a valid call, not an error block.
      assert body["result"]["isError"] == false
    end

    test "the documented minimum of 1 is accepted", %{conn: conn, raw: raw} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"limit" => 1}})
        |> json_response(200)

      assert body["result"]["isError"] == false
    end
  end

  describe "recent_runs summary fields" do
    test "a returned run carries run_id, action_id, runner, status, exit_code, reason, finished_at",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, raw, key} =
        ApiKeys.create_key(%{name: "reader-#{unique()}", scopes: ["actions:read"]}, subject)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          reason: "smoke test recall",
          args: %{}
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{}})
        |> json_response(200)

      # The compact summaries are JSON-encoded in the second content block.
      [_intro, json_block | _] = body["result"]["content"]
      [summary | _] = Jason.decode!(json_block["text"])

      assert summary["run_id"] == run.id
      assert summary["action_id"] == "linux.uptime"
      assert summary["runner"] == "host-1"
      assert summary["status"] == to_string(run.status)
      assert Map.has_key?(summary, "exit_code")
      assert summary["reason"] == "smoke test recall"
      assert Map.has_key?(summary, "finished_at")
    end
  end

  describe "idempotency per-api_key isolation" do
    test "two keys sharing the same idempotency string get two distinct runs",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")

      raw_a = make_api_key!(account, user)
      raw_b = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      call = fn raw ->
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{
            "runner" => "host-1",
            "reason" => "smoke",
            "wait" => "0",
            "idempotency_key" => "shared-key"
          }
        })
        |> json_response(200)
      end

      assert call.(raw_a)["result"]["isError"] == false
      assert call.(raw_b)["result"]["isError"] == false

      # The unique index is (api_key_id, idempotency_key) — same string on two
      # different keys is NOT a collision, so both produced their own run.
      {:ok, runs, _meta} = Runs.list_runs(subject)
      assert length(runs) == 2
      assert runs |> Enum.map(& &1.api_key_id) |> Enum.uniq() |> length() == 2
    end
  end

  describe "idempotency replay preserves the original outcome" do
    setup %{account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {:ok, raw: raw, subject: subject}
    end

    test "a replayed denied run surfaces denied_by_policy again",
         %{conn: conn, raw: raw, subject: subject} do
      # Flip the account policy so the low-risk action is denied.
      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "deny",
              "medium" => "deny",
              "high" => "deny",
              "critical" => "deny"
            },
            "overrides" => []
          },
          subject
        )

      call = fn ->
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{
            "runner" => "host-1",
            "reason" => "smoke",
            "wait" => "0",
            "idempotency_key" => "denied-replay"
          }
        })
        |> json_response(200)
      end

      first = call.()
      assert first["result"]["isError"] == true
      assert content_text(first) =~ "Denied by policy"

      # The replay re-shapes the cached denied row into the same deny outcome,
      # rendered byte-identically — never as a fresh running run.
      replay = call.()
      assert replay["result"]["isError"] == true
      assert content_text(replay) =~ "Denied by policy"

      # A denied dispatch is recorded once; the replay does not create a second.
      {:ok, runs, _meta} = Runs.list_runs(subject)
      assert length(runs) == 1
    end

    test "a replayed pending_approval run routes back to wait_for_run",
         %{conn: conn, raw: raw, subject: subject} do
      # Low-risk action now requires approval, so the dispatch parks pending.
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

      call = fn ->
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{
            "runner" => "host-1",
            "reason" => "smoke",
            "wait" => "0",
            "idempotency_key" => "pending-replay"
          }
        })
        |> json_response(200)
      end

      first = call.()
      assert first["result"]["isError"] == false
      assert content_text(first) =~ "pending approval"
      assert content_text(first) =~ "wait_for_run"

      # The replay returns the SAME pending run → still a wait tip, never a
      # re-pushed dispatch envelope.
      replay = call.()
      assert replay["result"]["isError"] == false
      assert content_text(replay) =~ "pending approval"
      assert content_text(replay) =~ "wait_for_run"

      # One parked run, not two.
      {:ok, runs, _meta} = Runs.list_runs(subject)
      assert length(runs) == 1
    end
  end

  describe "clientInfo capture (initialize)" do
    setup %{account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, raw, key} =
        ApiKeys.create_key(
          %{name: "ci-key-#{unique()}", scopes: ["actions:read", "actions:execute"]},
          subject
        )

      {:ok, raw: raw, key: key, subject: subject}
    end

    defp init_with_client_info(conn, raw, client_info) do
      params = if client_info == :omit, do: %{}, else: %{"clientInfo" => client_info}

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("initialize", params)
      |> json_response(200)
    end

    test "clientInfo with no name records nothing and preserves a prior value",
         %{conn: conn, raw: raw, key: key, subject: subject} do
      # Establish a good prior value.
      init_with_client_info(conn, raw, %{"name" => "Claude Code", "version" => "1.0"})
      {:ok, after_first} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert after_first.last_client_info == %{"name" => "Claude Code", "version" => "1.0"}

      # A name-less (and a garbage) clientInfo must NOT clobber the good prior.
      init_with_client_info(conn, raw, %{"version" => "9.9"})
      init_with_client_info(conn, raw, %{"junk" => "x", "version" => 123})

      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert reloaded.last_client_info == %{"name" => "Claude Code", "version" => "1.0"}
    end

    test "an oversized field is clipped to 200 chars",
         %{conn: conn, raw: raw, key: key, subject: subject} do
      init_with_client_info(conn, raw, %{"name" => String.duplicate("n", 300)})

      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert String.length(reloaded.last_client_info["name"]) == 200
    end

    test "a non-map clientInfo records nothing and never breaks the handshake",
         %{conn: conn, raw: raw, key: key, subject: subject} do
      body = init_with_client_info(conn, raw, "not-a-map")

      # Handshake still succeeds.
      assert body["result"]["protocolVersion"] == "2024-11-05"

      # Nothing recorded — the field stays at its empty default (never written).
      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert reloaded.last_client_info == %{}
    end
  end

  describe "cross-account read isolation (runbook verbs)" do
    test "list_runbooks never surfaces another account's published runbook",
         %{conn: conn, account: account, user: user} do
      other = setup_other_account()
      publish_runbook!(other.account, other.user, slug: "b-secret-runbook")

      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "list_runbooks", "arguments" => %{}})
        |> json_response(200)

      assert body["result"]["isError"] == false
      # Subject-scoped to account A — B's runbook is invisible, and the
      # friendly empty intro is shown instead.
      refute content_text(body) =~ "b-secret-runbook"
      assert content_text(body) =~ "No published runbooks in this account yet."
    end

    test "get_runbook on another account's slug reads as not found",
         %{conn: conn, account: account, user: user} do
      other = setup_other_account()
      publish_runbook!(other.account, other.user, slug: "b-cross-acct")

      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "get_runbook",
          "arguments" => %{"runbook" => "b-cross-acct"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Runbook not found"
    end
  end

  describe "get_runbook resolution (id + draft)" do
    test "resolves a published runbook by its id when the slug doesn't match",
         %{conn: conn, account: account, user: user} do
      runbook = publish_runbook!(account, user, slug: "by-id-lookup")
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "get_runbook",
          # Pass the id, not the slug — find_runbook falls back from slug to id.
          "arguments" => %{"runbook" => runbook.id}
        })
        |> json_response(200)

      assert body["result"]["isError"] == false
      assert content_text(body) =~ "by-id-lookup"
    end

    test "a draft runbook is not resolvable (only published) → not found",
         %{conn: conn, account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, draft} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "Draft only",
            "name" => "Draft only",
            "slug" => "still-a-draft",
            "definition" => %{"steps" => []}
          },
          subject
        )

      # Left unpublished on purpose — get_runbook resolves only published.
      assert draft.status == :draft

      raw = make_api_key!(account, user, scopes: ["actions:read"])

      for selector <- ["still-a-draft", draft.id] do
        body =
          conn
          |> put_req_header("authorization", "Bearer " <> raw)
          |> rpc("tools/call", %{
            "name" => "get_runbook",
            "arguments" => %{"runbook" => selector}
          })
          |> json_response(200)

        assert body["result"]["isError"] == true
        assert content_text(body) =~ "Runbook not found"
      end
    end
  end

  describe "recent_runs scope isolation + filters" do
    test "scope=own isolates per api_key — key B never sees key A's runs",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, raw_a, key_a} =
        ApiKeys.create_key(%{name: "a-#{unique()}", scopes: ["actions:read"]}, subject)

      {:ok, raw_b, _key_b} =
        ApiKeys.create_key(%{name: "b-#{unique()}", scopes: ["actions:read"]}, subject)

      # A run dispatched by key A (carries A's api_key_id).
      {:ok, a_run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key_a.id,
          args: %{}
        })

      # Key B, default scope (own), must NOT see A's run.
      b_body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw_b)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{}})
        |> json_response(200)

      refute content_text(b_body) =~ a_run.id

      # ...but key A sees its own run, so the row really exists.
      a_body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw_a)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{}})
        |> json_response(200)

      assert content_text(a_body) =~ a_run.id
    end

    test "scope=account widens to a sibling key's runs (same tenant)",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, _raw_a, key_a} =
        ApiKeys.create_key(%{name: "a-#{unique()}", scopes: ["actions:read"]}, subject)

      {:ok, raw_b, _key_b} =
        ApiKeys.create_key(%{name: "b-#{unique()}", scopes: ["actions:read"]}, subject)

      {:ok, a_run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key_a.id,
          args: %{}
        })

      # scope=account is account-wide visibility (F5, confirmed intended) — B
      # sees A's run, but it's still gated to the account by the Subject.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw_b)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"scope" => "account"}})
        |> json_response(200)

      assert content_text(body) =~ a_run.id
    end

    test "an unknown runner filter reports runner_not_found, not an empty list",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{"runner" => "ghost"}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "No such runner"
      assert content_text(body) =~ "ghost"
    end

    test "no matching runs renders the friendly empty intro",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "recent_runs", "arguments" => %{}})
        |> json_response(200)

      assert body["result"]["isError"] == false
      assert content_text(body) =~ "No matching runs yet."
    end
  end

  describe "per-call scope re-check (IL-15)" do
    test "initialize is ungated but the later tools/call still re-checks execute",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      auth = &put_req_header(&1, "authorization", "Bearer " <> raw)

      # Handshake succeeds for a read-only key (initialize isn't scope-gated).
      init = conn |> auth.() |> rpc("initialize") |> json_response(200)
      assert init["result"]["protocolVersion"] == "2024-11-05"

      # The dispatch re-checks execute on its OWN call — handshake success
      # never grants it. A read-only key is refused.
      call =
        conn
        |> auth.()
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "x", "wait" => "0"}
        })
        |> json_response(200)

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:execute"}}} =
               call
    end
  end

  describe "error taxonomy through dispatch (RPC content blocks)" do
    setup %{account: account} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      {:ok, runner: runner}
    end

    test "denied_by_policy renders the override reason verbatim + isError",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      # A named override deny gives a deterministic verbatim reason
      # ("Override: <name>") the renderer must echo unaltered.
      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "allow",
              "critical" => "allow"
            },
            "overrides" => [
              %{
                "name" => "block-uptime-maintenance",
                "action" => "linux.uptime",
                "decision" => "deny"
              }
            ]
          },
          subject
        )

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "smoke", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Denied by policy: Override: block-uptime-maintenance"
    end

    test "pending_approval is a tip, not an error (isError=false)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "smoke", "wait" => "0"}
        })
        |> json_response(200)

      # A parked run is guidance to wait, never an isError block.
      assert body["result"]["isError"] == false
      assert content_text(body) =~ "pending approval"
      assert content_text(body) =~ "wait_for_run"
    end

    test "an args changeset failure surfaces invalid_args with the offending field",
         %{conn: conn, account: account, user: user} do
      # The portal doesn't re-validate args against the runner's arg spec (the
      # runner does that) — the reachable changeset failure is the size guard.
      # Oversized args fail `validate_args_size` → `{:error, changeset}` →
      # the `invalid_args` block naming `args` in `details`.
      raw = make_api_key!(account, user)
      # > 256 KiB serialized — over @max_args_bytes.
      huge = String.duplicate("a", 300_000)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{
            "runner" => "host-1",
            "reason" => "smoke",
            "wait" => "0",
            "blob" => huge
          }
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      text = content_text(body)
      assert text =~ "invalid_args"
      assert text =~ "args"
    end
  end

  describe "error taxonomy — pack trust + attestation (RPC, end-to-end)" do
    test "pack_untrusted renders the directing block + isError, no run created",
         %{conn: conn, account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      # A custom (no-baseline) pack lands :pending — untrusted — so dispatch
      # is refused before any run row is created.
      runner = observe_pending_pack!(account)
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "custom.do",
          "arguments" => %{"runner" => runner.name, "reason" => "smoke", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      text = content_text(body)
      assert text =~ "pack_untrusted"
      # The renderer must direct the operator to Trust the pack and say a
      # retry won't clear it (the LLM kept retrying this in the wild).
      assert text =~ "Trust the pack"
      assert text =~ "NOT clear"

      # Refused before run creation — no orphan row.
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "runner_requires_attestation renders + the run isn't created",
         %{conn: conn, account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      runner = make_runner!(account, name: "signed-host")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      enforce_signatures!(runner)

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          # No attestation on the call — an enforcing runner refuses, and the
          # portal gate stops it before a run row exists.
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "signed-host", "reason" => "smoke", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "runner_requires_attestation"

      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "extra keys (top-level and in the cert) are stripped; only the known fields are kept",
         %{conn: conn, account: account, user: user} do
      # normalize_attestation builds the relayed envelope from the KNOWN fields
      # only (top-level sig/nonce/issued_at/cert; the cert's own seven strings +
      # scope), so an unexpected key at either level is silently dropped rather
      # than rejected. (Only a MISSING field or an oversized one → nil.)
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        "arguments" => %{
          "runner" => "host-1",
          "reason" => "smoke",
          "wait" => "0",
          "attestation" => %{
            "sig" => "deadbeef",
            "nonce" => "n1",
            "issued_at" => "2026-06-17T12:00:00Z",
            "extra" => "x",
            "cert" => %{
              "ca_id" => "ca-acme",
              "key_id" => "op-1",
              "public_key" => "ab",
              "valid_from" => "2026-06-25T00:00:00Z",
              "valid_until" => "2026-06-26T00:00:00Z",
              "scope" => %{},
              "serial" => "01X",
              "sig" => "cafe",
              "extra_cert" => "y"
            }
          }
        }
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      # The unexpected keys are gone at both levels; only the known fields remain.
      assert run.attestation == %{
               "sig" => "deadbeef",
               "nonce" => "n1",
               "issued_at" => "2026-06-17T12:00:00Z",
               "cert" => %{
                 "ca_id" => "ca-acme",
                 "key_id" => "op-1",
                 "public_key" => "ab",
                 "valid_from" => "2026-06-25T00:00:00Z",
                 "valid_until" => "2026-06-26T00:00:00Z",
                 "scope" => %{},
                 "serial" => "01X",
                 "sig" => "cafe"
               }
             }

      refute Map.has_key?(run.args, "attestation")
    end
  end

  describe "JSON-RPC frame edges" do
    test "a frame missing `method` is an invalid request (-32600 @ 400)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      # jsonrpc 2.0 but no `method` — the catch-all `handle/2` clause rejects it
      # before any dispatch, the same -32600 the non-2.0 frame gets, at HTTP 400.
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(%{jsonrpc: "2.0", id: 1}))

      assert %{"error" => %{"code" => -32600}, "id" => nil} = json_response(conn, 400)
    end

    test "a malformed JSON body is a JSON-RPC parse error (-32700)",
         %{conn: conn, account: account, user: user} do
      # The controller moduledoc promises "Parse errors → -32700", but a malformed
      # body is consumed by Plug.Parsers (endpoint-level) BEFORE the controller —
      # it raises Plug.Parsers.ParseError, which Phoenix renders as a plain 400, not
      # a JSON-RPC envelope. No handler maps the parse failure to -32700. Failing
      # closed at 400 is safe, but an MCP client parsing for the envelope won't find
      # it. Asserting the documented contract; skipped pending a parse-error handler.
      raw = make_api_key!(account, user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", "{not valid json")

      assert %{"error" => %{"code" => -32700}} = json_response(conn, 400)
    end

    test "a non-1 `id` is echoed back verbatim",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      # The id is opaque to the server — a string id round-trips unchanged so the
      # client can correlate the reply to its request.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("ping", %{}, "abc")
        |> json_response(200)

      assert body == %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{}}
    end

    test "omitting `params` defaults to an empty map (no crash)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      # `initialize` reads clientInfo out of params; a frame with NO params key at
      # all must default to %{} and handshake cleanly, not raise on a nil lookup.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize"}))
        |> json_response(200)

      assert body["result"]["protocolVersion"] == "2024-11-05"
    end

    test "a scope-denied tools/call returns the error body at HTTP 200, not 4xx",
         %{conn: conn, account: account, user: user} do
      # Only a malformed frame (400) or an auth failure (401, the plug) leave 200.
      # An in-band scope denial is a normal JSON-RPC error envelope at HTTP 200 so
      # the transport stays a single happy status and the client reads `error`.
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "x", "wait" => "0"}
        })

      assert conn.status == 200

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:execute"}}} =
               json_response(conn, 200)
    end
  end

  describe "tools/list descriptor body" do
    test "a tool's description carries side-effects, live runner status, and a Risk line",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "only-host")

      advertise_action!(runner,
        action_id: "linux.reboot",
        risk: "critical",
        description: "Reboots the host.",
        side_effects: ["reboots the machine", "drops all sessions"]
      )

      raw = make_api_key!(account, user)

      tool =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.find(&(&1["name"] == "linux.reboot"))

      desc = tool["description"]
      # Base text + each declared side effect ...
      assert desc =~ "Reboots the host."
      assert desc =~ "Side effects:"
      assert desc =~ "reboots the machine"
      assert desc =~ "drops all sessions"
      # ... the live (list-time) runner status for the single advertiser ...
      assert desc =~ "Runs on: only-host (connected)"
      # ... and the action's risk tier as a trailing Risk line.
      assert desc =~ "Risk: critical"
    end
  end

  describe "clientInfo capture (title + dispatch propagation)" do
    test "the optional `title` field is captured alongside name + version",
         %{conn: conn, account: account, user: user} do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, raw, key} =
        ApiKeys.create_key(
          %{name: "titled-#{unique()}", scopes: ["actions:read", "actions:execute"]},
          subject
        )

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("initialize", %{
        "clientInfo" => %{
          "name" => "Claude Desktop",
          "version" => "1.0",
          "title" => "Claude for Mac"
        }
      })
      |> json_response(200)

      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(key.id, subject)

      assert reloaded.last_client_info == %{
               "name" => "Claude Desktop",
               "version" => "1.0",
               "title" => "Claude for Mac"
             }
    end

    test "a run dispatched after initialize carries the captured client_info",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, raw, _key} =
        ApiKeys.create_key(
          %{name: "ci-dispatch-#{unique()}", scopes: ["actions:read", "actions:execute"]},
          subject
        )

      auth = &put_req_header(&1, "authorization", "Bearer " <> raw)

      # The handshake snapshots the client onto the key row...
      conn
      |> auth.()
      |> rpc("initialize", %{"clientInfo" => %{"name" => "Cursor", "version" => "0.42"}})
      |> json_response(200)

      # ...and a later dispatch on the same key stamps that snapshot onto the run.
      conn
      |> auth.()
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        "arguments" => %{"runner" => "host-1", "reason" => "smoke", "wait" => "0"}
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert run.client_info == %{"name" => "Cursor", "version" => "0.42"}
    end
  end

  describe "tools/list visibility (creator scope + catalog completeness)" do
    test "an action only an out-of-creator-scope runner advertises is hidden",
         %{conn: conn, account: account, user: user} do
      # Two runners in different groups; the key-creator's membership is scoped to
      # only the `allowed` group. The action on the out-of-scope runner must be
      # absent from tools/list — the per-user scope layer hides it even though the
      # key itself carries no runner_filter.
      allowed = make_runner!(account, name: "in-scope", group: "allowed")
      blocked = make_runner!(account, name: "out-scope", group: "blocked")
      advertise_action!(allowed, action_id: "visible.action")
      advertise_action!(blocked, action_id: "hidden.action")

      raw = make_api_key!(account, user)
      restrict_creator_scope!(account, user, [{"group", "allowed"}])

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])

      assert "visible.action" in names
      refute "hidden.action" in names
    end

    test "the complete catalog is returned unpaginated (hundreds of actions)",
         %{conn: conn, account: account, user: user} do
      # The MCP reads the COMPLETE catalog (Service uses page: [limit: 1000]+);
      # there is no MCP-side pagination. Seed well past a default page size and
      # assert every distinct action tool comes back in one tools/list.
      runner = make_runner!(account, name: "host-1")
      ids = for i <- 1..150, do: "bulk.action_#{String.pad_leading(to_string(i), 3, "0")}"
      for id <- ids, do: advertise_action!(runner, action_id: id)

      raw = make_api_key!(account, user)

      names =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])
        |> MapSet.new()

      # Every seeded action is present — none dropped to a page boundary.
      assert Enum.all?(ids, &MapSet.member?(names, &1))
    end

    test "the catalog is re-fetched per call — a runner added between calls shows up",
         %{conn: conn, account: account, user: user} do
      # Resolution reads the live catalog + runner set on EVERY call (no caching),
      # so inventory mutated between two tools/list calls is reflected immediately.
      raw = make_api_key!(account, user)
      auth = &put_req_header(&1, "authorization", "Bearer " <> raw)

      tools = fn ->
        conn
        |> auth.()
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])
      end

      r1 = make_runner!(account, name: "first-host")
      advertise_action!(r1, action_id: "first.action")
      assert "first.action" in tools.()
      refute "second.action" in tools.()

      # Add a new runner + action AFTER the first list, then re-list on the same key.
      r2 = make_runner!(account, name: "second-host")
      advertise_action!(r2, action_id: "second.action")

      names = tools.()
      assert "first.action" in names
      assert "second.action" in names
    end
  end

  describe "dispatch attribution + control-key stripping (RPC)" do
    setup %{account: account} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      {:ok, runner: runner}
    end

    test "the dispatched run carries source/api_key_id/session/membership/client_info",
         %{conn: conn, account: account, user: user} do
      subject = subject_for(account, user)

      {:ok, raw, key} =
        ApiKeys.create_key(
          %{name: "attrib-#{unique()}", scopes: ["actions:read", "actions:execute"]},
          subject
        )

      # Snapshot a client onto the key first, so the dispatch can stamp it.
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("initialize", %{"clientInfo" => %{"name" => "Claude Code", "version" => "9.9"}})
      |> json_response(200)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("mcp-session-id", "sess-attrib-1")
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        "arguments" => %{"runner" => "host-1", "reason" => "attribution", "wait" => "0"}
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      # source is hard-coded "mcp" for every MCP dispatch (F7) — an Ecto.Enum,
      # so it loads as the atom :mcp. The kind (emk-/RPC here) is distinguished
      # only by api_key_id + client_info, never by source.
      assert run.source == :mcp
      assert run.api_key_id == key.id
      assert run.mcp_session_id == "sess-attrib-1"
      assert run.client_info == %{"name" => "Claude Code", "version" => "9.9"}
      # NOTE: the key's creator membership is threaded as `requested_by_membership_id`
      # into dispatch ONLY to run the per-user runner-scope gate — it's consumed and
      # dropped before the run is created (ActionRun has no such column), so the
      # stored attribution is the api_key_id, which carries the membership link.
      refute Map.has_key?(run, :requested_by_membership_id)
    end

    test "control keys are stripped from the action args the runner sees",
         %{conn: conn, account: account, user: user, runner: runner} do
      # Advertise an action with a real arg so it's distinguishable from the
      # reserved control keys in the stored args map.
      advertise_action!(runner,
        action_id: "linux.touch",
        args_schema: %{"args" => [%{"name" => "path", "type" => "string", "required" => true}]}
      )

      raw = make_api_key!(account, user)
      subject = subject_for(account, user)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.touch",
        "arguments" => %{
          "runner" => "host-1",
          "reason" => "strip",
          "wait" => "0",
          "idempotency_key" => "k-#{unique()}",
          "attestation" => %{
            "key_id" => "k1",
            "sig" => "x",
            "nonce" => "n",
            "issued_at" => "2026-06-17T12:00:00Z"
          },
          "path" => "/tmp/marker"
        }
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      # Only the genuine action arg survives — every control key (runner/reason/
      # wait/idempotency_key/attestation) is dropped before the runner sees args.
      assert run.args == %{"path" => "/tmp/marker"}

      for k <- ~w(runner runners reason wait idempotency_key attestation),
          do: refute(Map.has_key?(run.args, k))
    end

    test "a missing reason is rejected up-front (reason_required), not a crash",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)
      subject = subject_for(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "Reason required"
      # Gated before run creation — no orphan row.
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "a valid reason is stored verbatim on the run",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)
      subject = subject_for(account, user)

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        "arguments" => %{
          "runner" => "host-1",
          "reason" => "investigating the 02:14 oom on host-1",
          "wait" => "0"
        }
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert run.reason == "investigating the 02:14 oom on host-1"
    end
  end

  describe "dispatch deny matrix (RPC, runner resolution)" do
    test "a disabled named runner is runner_not_allowed with the disabled reason",
         %{conn: conn, account: account, user: user} do
      runner = make_runner!(account, name: "soon-disabled")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      subject = subject_for(account, user)
      {:ok, _} = Runners.disable_runner(runner, subject)

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "soon-disabled", "reason" => "x", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      text = content_text(body)
      assert text =~ "Runner not allowed"
      assert text =~ "disabled"
    end

    test "a named runner outside the creator's user scope is runner_not_allowed (scope reason)",
         %{conn: conn, account: account, user: user} do
      allowed = make_runner!(account, name: "in-scope", group: "allowed")
      blocked = make_runner!(account, name: "out-scope", group: "blocked")
      advertise_action!(allowed, action_id: "linux.uptime", risk: "low")
      advertise_action!(blocked, action_id: "linux.uptime", risk: "low")

      raw = make_api_key!(account, user)
      restrict_creator_scope!(account, user, [{"group", "allowed"}])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "out-scope", "reason" => "x", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      text = content_text(body)
      assert text =~ "Runner not allowed"
      # deny_reason names the user-scope layer, not the key filter.
      assert text =~ "runner-scope grant"
    end

    test "scope_blocked never reveals the unreachable runner's name",
         %{conn: conn, account: account, user: user} do
      # An action exists in the account but only on a runner outside the creator
      # scope. Auto-pick (no `runners` arg) → scope_blocked. The message must say
      # it exists somewhere unreachable WITHOUT naming the runner that has it.
      reachable = make_runner!(account, name: "reachable-host", group: "allowed")
      hidden = make_runner!(account, name: "secret-host-xyz", group: "blocked")
      advertise_action!(reachable, action_id: "common.action")
      advertise_action!(hidden, action_id: "secret.action")

      raw = make_api_key!(account, user)
      restrict_creator_scope!(account, user, [{"group", "allowed"}])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "secret.action",
          "arguments" => %{"reason" => "x", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      text = content_text(body)
      assert text =~ "No runner in scope"
      # The message frames it as an access grant on an action that exists
      # somewhere unreachable — never confirming which runner has it.
      assert text =~ "no runner you're allowed to reach advertises it"
      assert text =~ "access grant"
      # The specific runner that DOES advertise it is never disclosed.
      refute text =~ "secret-host-xyz"
    end
  end

  describe "attestation enforce + relay (RPC)" do
    setup %{account: account} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      {:ok, runner: runner}
    end

    test "a non-enforcing runner ignores an absent attestation and dispatches",
         %{conn: conn, account: account, user: user} do
      # The shared-setup runner does NOT enforce signatures, so a call with no
      # attestation dispatches normally — the run is created with attestation nil.
      raw = make_api_key!(account, user)
      subject = subject_for(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "no-att", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == false
      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert run.attestation == nil
    end

    test "the portal relays a well-formed attestation verbatim without verifying it",
         %{conn: conn, account: account, user: user} do
      # The portal can't verify Ed25519 — the runner does. So even a signature
      # the portal has no way to check is stored byte-for-byte on the run (for
      # audit + relay), never forged or rejected portal-side. We give a
      # well-formed-but-cryptographically-bogus envelope and assert it persists.
      raw = make_api_key!(account, user)
      subject = subject_for(account, user)

      bogus_but_well_formed = %{
        "sig" => "not-a-real-signature-but-the-right-shape",
        "nonce" => "nonce-123",
        "issued_at" => "2026-06-17T12:00:00Z",
        "cert" => %{
          "ca_id" => "ca-acme",
          "key_id" => "operator-key-1",
          "public_key" => "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664",
          "valid_from" => "2026-06-25T00:00:00Z",
          "valid_until" => "2026-06-26T00:00:00Z",
          "scope" => %{"group" => "edge"},
          "serial" => "01J0CERT0000000000000000A",
          "sig" => "also-not-real-but-right-shape"
        }
      }

      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> rpc("tools/call", %{
        "name" => "linux.uptime",
        "arguments" => %{
          "runner" => "host-1",
          "reason" => "relay",
          "wait" => "0",
          "attestation" => bogus_but_well_formed
        }
      })
      |> json_response(200)

      {:ok, [run], _meta} = Runs.list_runs(subject)
      # Stored verbatim — the portal relayed it untouched for the runner to judge.
      assert run.attestation == bogus_but_well_formed
    end
  end

  describe "wait_for_run argument + cap edges (RPC)" do
    test "a blank run_id is a bad-arguments error block",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => "", "timeout" => ""}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "requires `run_id`"
    end

    test "the wait_for_run timeout clamps any over-cap duration to the 90s server cap" do
      # The wait_for_run descriptor copy says "5m", but the server caps at
      # @max_get_run_wait_ms (90s) so a long-poll can't pin a request process for
      # five minutes. Assert the cap CONSTANT + clamp BRANCH rather than sleeping:
      # the RPC handler runs `parse_wait(timeout, max_get_run_wait_ms())`, which
      # clamps anything over the cap (and the documented "300s"/"600s") to 90_000ms.
      assert Service.max_get_run_wait_ms() == 90_000
      assert Service.parse_wait("600s", Service.max_get_run_wait_ms()) == {:ok, 90_000}
      assert Service.parse_wait("300s", Service.max_get_run_wait_ms()) == {:ok, 90_000}
      # At/under the cap passes through unchanged.
      assert Service.parse_wait("90s", Service.max_get_run_wait_ms()) == {:ok, 90_000}
      assert Service.parse_wait("30s", Service.max_get_run_wait_ms()) == {:ok, 30_000}
    end
  end

  describe "inline wait arg edges (RPC tools/call)" do
    setup %{account: account} do
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      {:ok, runner: runner}
    end

    test ~s|an explicit wait:"0" is fire-and-forget — returns immediately with a run_id|,
         %{conn: conn, account: account, user: user} do
      # A wait:"0" dispatch must return immediately with the dispatched run's id
      # + a wait_for_run tip so the LLM can poll — never a dead-end bare status.
      # The run IS created (status :sent), but the RPC content renders it as
      # "(no output)" because full_run_payload carries the status as the atom
      # :sent and ContentBlocks only reads string status values, so the in-flight
      # branch is missed. Asserting the CORRECT contract; skipped pending the fix
      # (stringify status in full_run_payload, or atom-aware status read in
      # ContentBlocks). The REST surface is unaffected — Jason encodes :sent →
      # "sent" on the wire, so only the pre-encode RPC render path regresses.
      raw = make_api_key!(account, user)
      subject = subject_for(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "linux.uptime",
          "arguments" => %{"runner" => "host-1", "reason" => "fire-forget", "wait" => "0"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == false
      {:ok, [run], _meta} = Runs.list_runs(subject)
      assert content_text(body) =~ run.id
      assert content_text(body) =~ "wait_for_run"
    end

    test "an unparseable wait is rejected by parse_wait (the handler then uses the full window)" do
      # The RPC handle_tool_call maps an invalid `wait` to the full max_wait_ms
      # (60s), NOT to 0 (fire-and-forget) — the LLM fumbling `wait` should still
      # block for output. Assert the two halves of that fallback as CONSTANTS (no
      # sleeping): parse_wait rejects the junk with :error, and the full window the
      # handler falls back to is 60s.
      assert Service.parse_wait("abc", Service.max_wait_ms()) == :error
      assert Service.parse_wait("soon", Service.max_wait_ms()) == :error
      assert Service.max_wait_ms() == 60_000
    end
  end

  describe "cross-account run never reaches the rendered payload (RPC wait_for_run)" do
    test "a foreign-account run id is not_found before full_run_payload is built",
         %{conn: conn, account: account, user: user} do
      # Distinct from the REST get_run 404 path: here the RPC
      # wait_for_run → Service.fetch_run subject-scopes the lookup, so a foreign
      # run id returns {:error, :not_found} and full_run_payload (the output/hash/
      # policy renderer) is NEVER reached — no payload field leaks across tenants.
      other = setup_other_account()
      b_runner = make_runner!(other.account, name: "b-host")

      {:ok, b_run} =
        Runs.create_run(%{
          account_id: other.account.id,
          runner_id: b_runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          reason: "B-private-reason-should-never-render",
          args: %{},
          status: "success"
        })

      raw = make_api_key!(account, user)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => b_run.id, "timeout" => ""}
        })
        |> json_response(200)

      assert body["result"]["isError"] == true
      text = content_text(body)
      assert text =~ "Run not found"
      # No field of B's run rendered — neither its id nor its private reason.
      refute text =~ "B-private-reason"
    end
  end

  describe "list_runbooks read edges (RPC)" do
    test "an execute-only key is denied list_runbooks (needs actions:read)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:execute"])

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:read"}}} =
               conn
               |> put_req_header("authorization", "Bearer " <> raw)
               |> rpc("tools/call", %{"name" => "list_runbooks", "arguments" => %{}})
               |> json_response(200)
    end

    test "no published runbooks renders the friendly empty intro",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "list_runbooks", "arguments" => %{}})
        |> json_response(200)

      assert body["result"]["isError"] == false
      assert content_text(body) =~ "No published runbooks in this account yet."
    end

    test "a draft runbook is excluded — only published are listed",
         %{conn: conn, account: account, user: user} do
      subject = subject_for(account, user)

      # A published one (shows) ...
      published = publish_runbook!(account, user, slug: "live-rb")

      # ... and a draft (must NOT show).
      {:ok, _draft} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "draft-rb",
            "name" => "draft-rb",
            "slug" => "draft-rb",
            "definition" => %{"steps" => []}
          },
          subject
        )

      raw = make_api_key!(account, user, scopes: ["actions:read"])

      text =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "list_runbooks", "arguments" => %{}})
        |> json_response(200)
        |> content_text()

      assert text =~ published.slug
      refute text =~ "draft-rb"
    end
  end

  describe "get_runbook read edges (RPC)" do
    test "an execute-only key is denied get_runbook (needs actions:read)",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:execute"])

      assert %{"error" => %{"code" => -32002, "data" => %{"required" => "actions:read"}}} =
               conn
               |> put_req_header("authorization", "Bearer " <> raw)
               |> rpc("tools/call", %{"name" => "get_runbook", "arguments" => %{"runbook" => "x"}})
               |> json_response(200)
    end

    test "a blank runbook arg is a bad-arguments error block",
         %{conn: conn, account: account, user: user} do
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{"name" => "get_runbook", "arguments" => %{"runbook" => ""}})
        |> json_response(200)

      assert body["result"]["isError"] == true
      assert content_text(body) =~ "requires `runbook`"
    end

    test "a step selector matching no live runner resolves to an empty target.runners",
         %{conn: conn, account: account, user: user} do
      # Publish a runbook whose step targets a group with NO connected runner. The
      # detail still resolves, but target.runners is empty and the guidance tells
      # the LLM to pick a runner from tools/list.
      subject = subject_for(account, user)

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "ghost-target",
            "name" => "ghost-target",
            "slug" => "ghost-target",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "s1",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"group" => ["nonexistent-group"]}
                }
              ]
            }
          },
          subject
        )

      {:ok, _} = Emisar.Runbooks.publish(runbook, subject)
      raw = make_api_key!(account, user, scopes: ["actions:read"])

      detail =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "get_runbook",
          "arguments" => %{"runbook" => "ghost-target"}
        })
        |> json_response(200)

      assert detail["result"]["isError"] == false
      # The JSON detail block carries a step whose target.runners is empty.
      [_guidance, json_block | _] = detail["result"]["content"]
      decoded = Jason.decode!(json_block["text"])
      [step | _] = decoded["steps"]
      assert step["target"]["runners"] == []
    end
  end

  describe "recent_runs runner + action filters (RPC)" do
    test "runner and action filters narrow the returned runs",
         %{conn: conn, account: account, user: user} do
      subject = subject_for(account, user)
      web = make_runner!(account, name: "web1")
      db = make_runner!(account, name: "db1")

      {:ok, raw, key} =
        ApiKeys.create_key(%{name: "filter-#{unique()}", scopes: ["actions:read"]}, subject)

      # Three runs by this key: the target (web1 + nginx.reload) and two decoys
      # that each differ on exactly one filtered dimension.
      mk = fn runner, action_id ->
        {:ok, run} =
          Runs.create_run(%{
            account_id: account.id,
            runner_id: runner.id,
            action_id: action_id,
            source: "mcp",
            api_key_id: key.id,
            args: %{}
          })

        run
      end

      target = mk.(web, "nginx.reload")
      decoy_other_action = mk.(web, "linux.uptime")
      decoy_other_runner = mk.(db, "nginx.reload")

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "recent_runs",
          "arguments" => %{"runner" => "web1", "action" => "nginx.reload"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == false
      text = content_text(body)
      assert text =~ target.id
      refute text =~ decoy_other_action.id
      refute text =~ decoy_other_runner.id
    end
  end

  describe "initialize capabilities (no server-push)" do
    test "advertises tools.listChanged=false — the client must re-list, never a push",
         %{conn: conn, account: account, user: user} do
      # The server has no `notifications/tools/list_changed` channel: tools/list is
      # a point-in-time snapshot the client re-polls. The handshake pins that by
      # advertising listChanged=false, so a conformant client never waits for a push.
      raw = make_api_key!(account, user)

      caps =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("initialize")
        |> json_response(200)
        |> get_in(["result", "capabilities"])

      assert caps == %{"tools" => %{"listChanged" => false}}
    end
  end

  describe "tools/list with an orphaned action (no live runner)" do
    test "an action whose only runner row is gone is still listed, with empty runners",
         %{conn: conn, account: account, user: user} do
      # The catalog (RunnerAction rows) outlives the runner row: soft-deleting the
      # runner drops it from list_all_runners_for_account (not_deleted), but its
      # advertised action persists. The descriptor still appears so the LLM sees the
      # capability — with an empty `runners` enum, since nothing live advertises it.
      runner = make_runner!(account, name: "soon-gone")
      advertise_action!(runner, action_id: "orphan.action", risk: "low")

      # Tombstone the runner row, leaving the RunnerAction row orphaned.
      {1, _} =
        Repo.update_all(
          from(r in Runner, where: r.id == ^runner.id),
          set: [deleted_at: DateTime.utc_now()]
        )

      raw = make_api_key!(account, user)

      tool =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/list")
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.find(&(&1["name"] == "orphan.action"))

      # Present (the capability is discoverable) ...
      assert tool
      # ... but no runner enum, because no live runner advertises it. The schema
      # omits the `runners` property entirely when there are zero advertisers.
      refute Map.has_key?(tool["inputSchema"]["properties"], "runners")
    end
  end

  describe "reason gate lives at the context layer (IL)" do
    test "Runs.dispatch_run rejects a missing reason before any run row exists",
         %{account: account, user: user} do
      # The MCP boundary now rejects a missing reason up-front (covered elsewhere),
      # but `Runs.dispatch_run` is the real gate: it runs `require_reason` in its
      # `with` chain BEFORE creating the run, so the rejection holds even when a
      # caller bypasses both the schema hint and the MCP boundary check. Assert the
      # context function directly — the security boundary, not the MCP rendering.
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      subject = subject_for(account, user)

      base = %{
        action_id: "linux.uptime",
        runner_id: runner.id,
        args: %{},
        source: "mcp"
      }

      # nil reason and whitespace-only reason are both rejected at the context layer.
      assert {:error, :reason_required} = Runs.dispatch_run(base, subject)

      assert {:error, :reason_required} =
               Runs.dispatch_run(Map.put(base, :reason, "   "), subject)

      # The gate fires before run creation — no orphan row from either attempt.
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end
  end

  describe "inline wait does not block on a pending_approval run" do
    test "a require_approval dispatch with a long wait returns immediately with the tip",
         %{conn: conn, account: account, user: user} do
      # maybe_poll_to_terminal only polls runs that came back `:running`; a
      # `:pending_approval` run is never inline-waited (a human gate could take
      # minutes). So even a full-window `wait` returns at once with the wait_for_run
      # tip — proven here by the call completing well under the wait it requested.
      runner = make_runner!(account, name: "host-1")
      advertise_action!(runner, action_id: "linux.uptime", risk: "low")
      raw = make_api_key!(account, user)
      subject = subject_for(account, user)

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

      {elapsed_us, body} =
        :timer.tc(fn ->
          conn
          |> put_req_header("authorization", "Bearer " <> raw)
          |> rpc("tools/call", %{
            "name" => "linux.uptime",
            # A 60s wait the handler would honor for a :running run — but a parked
            # run isn't polled, so this returns at once, not after the window.
            "arguments" => %{"runner" => "host-1", "reason" => "approve-me", "wait" => "60s"}
          })
          |> json_response(200)
        end)

      assert body["result"]["isError"] == false
      assert content_text(body) =~ "pending approval"
      assert content_text(body) =~ "wait_for_run"
      # Returned far under the requested 60s window — it never blocked on the gate.
      assert elapsed_us < 5_000_000
    end
  end

  describe "inline wait clamp (RPC tools/call)" do
    test "an over-cap inline wait clamps to the 60s max_wait_ms" do
      # handle_tool_call runs `parse_wait(wait, max_wait_ms())`, so any duration past
      # the inline cap is clamped to 60s — a tools/call can't pin a request process
      # longer than the dispatch window. Assert the cap CONSTANT + clamp branch (no
      # sleeping); the over-cap "5m" the LLM might pass collapses to 60_000ms.
      assert Service.max_wait_ms() == 60_000
      assert Service.parse_wait("5m", Service.max_wait_ms()) == {:ok, 60_000}
      assert Service.parse_wait("600s", Service.max_wait_ms()) == {:ok, 60_000}
      # At/under the cap is unchanged.
      assert Service.parse_wait("60s", Service.max_wait_ms()) == {:ok, 60_000}
      assert Service.parse_wait("15s", Service.max_wait_ms()) == {:ok, 15_000}
    end
  end

  describe "wait_for_run recheck timer (missed-broadcast safety net)" do
    test "a terminal transition with no broadcast is still caught by the ~2s recheck",
         %{conn: conn, account: account, user: user} do
      # The long-poll is event-driven (wakes on the run's `{:run_updated, _}`
      # broadcast) with a ~2s recheck timer as the safety net. Here we transition
      # the run to terminal via a RAW update_all — which does NOT broadcast — so the
      # await loop gets no PubSub signal and must fall back to the recheck timer's
      # re-fetch to notice the run finished. It still returns the terminal output.
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

      test_pid = self()

      Task.start(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Emisar.Repo, test_pid, self())
        # Land the terminal state mid-wait WITHOUT a broadcast — update_all bypasses
        # the Runs broadcast helpers, so only the recheck timer can surface it.
        # credo:disable-for-next-line Emisar.Checks.TestNoProcessSleep
        Process.sleep(50)

        {1, _} =
          Repo.update_all(
            from(r in Emisar.Runs.ActionRun, where: r.id == ^run.id),
            set: [status: :success, exit_code: 0, finished_at: DateTime.utc_now()]
          )
      end)

      # A wait window comfortably past the 2s recheck interval so the safety net
      # fires at least once.
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> rpc("tools/call", %{
          "name" => "wait_for_run",
          "arguments" => %{"run_id" => run.id, "timeout" => "5s"}
        })
        |> json_response(200)

      assert body["result"]["isError"] == false
      # The recheck timer re-fetched, saw the run had finalized, and rendered the
      # terminal block — proven by the exit code surfacing despite no broadcast ever
      # arriving. (The `status=` word is absent here because full_run_payload carries
      # the status as the Ecto.Enum atom :success and ContentBlocks reads only binary
      # status values — the separate render bug; the numeric exit_code is
      # unaffected and is the unambiguous proof the terminal payload was reached.)
      assert content_text(body) =~ "exit_code=0"
    end
  end

  describe "rate limiting (under-limit + pre-auth IP fallback)" do
    # The MCP controllers wire `plug RateLimit, by: :bearer` FIRST (before
    # :authenticate). The limiter is disabled suite-wide so shared counters don't
    # flake the fast suite, so — as the over-limit test does — we drive the plug
    # directly with a small bucket to pin behaviour the MCP surface depends on.
    setup do
      previous = Application.get_env(:emisar_web, :rate_limit_enabled, true)
      Application.put_env(:emisar_web, :rate_limit_enabled, true)
      on_exit(fn -> Application.put_env(:emisar_web, :rate_limit_enabled, previous) end)
      :ok
    end

    test "every call under the limit passes (no throttle)", %{conn: conn} do
      opts =
        RateLimit.init(bucket: "mcp-under-#{unique()}", limit: 5, window_ms: 60_000, by: :bearer)

      keyed = put_req_header(conn, "authorization", "Bearer emk-under")

      # Five calls within a five-request window all pass untouched.
      for _ <- 1..5, do: assert(%{halted: false} = RateLimit.call(keyed, opts))
    end

    test "a no-bearer flood is capped on the IP fallback before auth can run", %{conn: conn} do
      # `by: :bearer` falls back to the client IP when no bearer is present, and the
      # limiter plug sits BEFORE :authenticate — so an unauthenticated hammer is
      # throttled on its IP bucket without ever reaching the auth plug. Same conn
      # (same IP) on every call, no Authorization header at all.
      opts = RateLimit.init(bucket: "mcp-ip-#{unique()}", limit: 2, window_ms: 60_000, by: :ip)

      assert %{halted: false} = RateLimit.call(conn, opts)
      assert %{halted: false} = RateLimit.call(conn, opts)

      over = RateLimit.call(conn, opts)
      assert over.halted
      assert over.status == 429
      assert over.resp_body =~ "rate_limited"
    end
  end

  # -- Shared helpers for the additions above --------------------------

  # Restrict the key-creator's membership to the given runner/group scopes (string
  # tuples, e.g. [{"group", "allowed"}]), so every key that membership minted is
  # narrowed by the per-user scope layer. Mirrors the team page's scope editor.
  defp restrict_creator_scope!(account, user, scopes) do
    subject = subject_for(account, user)
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    {:ok, :ok} = Runners.replace_runner_scopes(membership, scopes, subject)
    :ok
  end

  # Create + publish a one-step runbook in `account`, returning the runbook.
  defp publish_runbook!(account, user, opts) do
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    slug = opts[:slug] || "rb-#{unique()}"

    {:ok, runbook} =
      Emisar.Runbooks.create_runbook(
        %{
          "title" => slug,
          "name" => slug,
          "slug" => slug,
          "definition" => %{
            "steps" => [
              %{
                "id" => "s1",
                "action_id" => "linux.uptime",
                "args" => %{},
                # Publishing requires every step to carry a runner/group target.
                "runner_selector" => %{"group" => ["default"]}
              }
            ]
          }
        },
        subject
      )

    {:ok, published} = Emisar.Runbooks.publish(runbook, subject)
    published
  end

  # Advertise a custom (no-baseline) pack + its action via observe_state so the
  # pack_version lands :pending (untrusted) — the dispatch gate refuses it.
  defp observe_pending_pack!(account) do
    runner = make_runner!(account, name: "untrusted-host")

    {:ok, _} =
      Emisar.Catalog.observe_state(runner, %{
        "hostname" => "h",
        "version" => "0.1",
        "labels" => %{},
        "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:NOPE"}},
        "actions" => [
          %{
            "id" => "custom.do",
            "pack_id" => "custom",
            "title" => "Do",
            "kind" => "exec",
            "risk" => "low",
            "args" => []
          }
        ]
      })

    runner
  end

  # Flip a runner to enforce client signatures. register/2 doesn't cast the
  # flag (it's runner-internal), so set it on the row directly — the same shape
  # the context tests use to stage dispatch-gate flags.
  defp enforce_signatures!(runner) do
    {1, _} =
      Repo.update_all(
        from(r in Runner, where: r.id == ^runner.id),
        set: [enforce_signatures: true]
      )

    runner
  end

  # A second, fully-independent tenant (account + owner) so isolation tests
  # can stage rows the calling key must never see.
  defp setup_other_account do
    {account, user} = setup_account()
    %{account: account, user: user}
  end

  defp subject_for(account, user), do: Fixtures.Subjects.subject_for(user, account, role: :owner)

  # Drive the real OAuth flow (PKCE register → issue code → exchange), returning
  # `{emo_access_token, backing_key}`. issue_code mints its OWN backing api key,
  # so the token backs onto a fresh key (not any caller-held emk-). The same flow
  # Claude.ai / ChatGPT connectors run; mirrors the existing "emo- OAuth token
  # sees the runbook tools" test so both paths exercise one helper.
  defp mint_oauth_token!(account, user) do
    subject = subject_for(account, user)
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

    # The backing key OAuth minted for this token — the one carrying scope +
    # attribution that resolve_access_token loads on each call.
    %{api_key_id: api_key_id} = Repo.peek(oauth_token_query(tokens.access_token))
    {:ok, key} = ApiKeys.fetch_api_key_by_id(api_key_id, subject)
    {tokens.access_token, key}
  end

  defp oauth_token_query(access_token) do
    Emisar.OAuth.Token.Query.all()
    |> Emisar.OAuth.Token.Query.by_access_hash(Emisar.Crypto.hash(access_token))
  end
end
