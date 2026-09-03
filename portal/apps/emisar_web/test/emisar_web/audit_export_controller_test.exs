defmodule EmisarWeb.AuditExportControllerTest do
  @moduledoc """
  End-to-end coverage for the SIEM audit export endpoint
  (`GET /api/audit`). Validates the contract every log shipper relies on:

    * NDJSON response — one event per line, `application/x-ndjson`
    * Forward-ordered by `(occurred_at, id)` so a paging consumer
      never skips or re-reads rows
    * Full page: both `X-Next-Cursor` (resume point) and `Link: rel="next"`
    * Tail (below-limit) page: `X-Next-Cursor` only — no `Link`, but still a
      resume point, so the short page's rows are never re-read
    * Empty page: no headers at all (signals "you're caught up")
    * `?cursor=<prior next>` resumes strictly after the last delivered row
    * `?event_type=` restricts; CSV form works too
    * `kind: :audit_export` gate — an `:mcp` key gets 403 wrong_key_kind
    * Unauthenticated → 401
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Audit, PublicUrl, Repo}

  setup do
    {user, account, subject} = Fixtures.Subjects.owner_subject()
    # Export is Team+ — these tests exercise the feed itself.
    Fixtures.Accounts.create_subscription(account, "team")

    {raw, _key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        created_by_id: user.id,
        kind: :audit_export
      )

    %{account: account, subject: subject, raw_key: raw}
  end

  test "a key on a downgraded plan is refused with an upgrade pointer", %{} do
    # The mint itself is entitlement-gated, so the ineligible-plan key can only
    # exist via a downgrade: minted on Team, then the entitlement withdrawn.
    {free_user, free_account, _subject} = Fixtures.Subjects.owner_subject()
    Fixtures.Accounts.create_subscription(free_account, "team")

    {raw, _key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: free_account.id,
        created_by_id: free_user.id,
        kind: :audit_export
      )

    Fixtures.Accounts.create_subscription(free_account, "team",
      entitlements: %{"features_audit_export_enabled?" => false}
    )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get(~p"/api/audit")

    assert %{"error" => "plan_required", "required" => "team"} = json_response(conn, 403)
  end

  defp insert_event(account, event_type, attrs \\ []) do
    base = %{
      actor_kind: "system",
      target_kind: "user",
      target_id: Ecto.UUID.generate(),
      payload: %{}
    }

    {:ok, ev} = Audit.log(account.id, event_type, Map.merge(base, Map.new(attrs)))
    ev
  end

  defp bearer(conn, raw),
    do: put_req_header(conn, "authorization", "Bearer #{raw}")

  defp ndjson(conn), do: Phoenix.ConnTest.response(conn, 200)

  defp parse_ndjson(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp export_markers(subject) do
    {:ok, events, _} = Audit.list_events(subject, page: [limit: 50])
    Enum.filter(events, &(&1.event_type == "audit.exported"))
  end

  describe "auth" do
    test "401 when no Authorization header", %{conn: conn} do
      conn = get(conn, ~p"/api/audit")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 when bearer token doesn't match any key", %{conn: conn} do
      conn = conn |> bearer("emk-bogus-not-a-real-key") |> get(~p"/api/audit")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "the auth scheme is case-insensitive, as RFC 9110 requires", %{
      conn: conn,
      raw_key: raw
    } do
      conn =
        conn
        |> put_req_header("authorization", "bearer #{raw}")
        |> get(~p"/api/audit")

      assert response(conn, 200)
    end

    test "403 when an mcp key hits the audit stream (wrong kind)", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {raw, _} =
        Fixtures.ApiKeys.create_api_key(
          account_id: account.id,
          created_by_id: subject.actor.id,
          kind: :mcp
        )

      conn = conn |> bearer(raw) |> get(~p"/api/audit")
      body = json_response(conn, 403)
      assert body["error"] == "wrong_key_kind"
      assert body["required"] == "audit_export"
    end

    test "401 when the key belongs to a disabled account", %{
      conn: conn,
      account: account,
      raw_key: raw,
      subject: subject
    } do
      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "support incident",
                 subject
               )

      conn = conn |> bearer(raw) |> get(~p"/api/audit")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 after the member who minted the export key is suspended", %{
      account: account,
      subject: owner_subject
    } do
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "admin"
        )

      {raw, _key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: account.id,
          created_by_id: member.id,
          kind: :audit_export
        )

      assert build_conn() |> bearer(raw) |> get(~p"/api/audit") |> response(200)
      assert {:ok, _suspended} = Accounts.suspend_membership(membership, owner_subject)

      conn = build_conn() |> bearer(raw) |> get(~p"/api/audit")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 while the key owner has not accepted their invitation", %{
      account: account
    } do
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "admin"
        )

      {raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: account.id,
          created_by_id: member.id,
          kind: :audit_export
        )

      {_token, digest} = Emisar.Crypto.user_invite_token()

      membership
      |> Ecto.Changeset.change(invitation_token_digest: digest, invitation_accepted_at: nil)
      |> Emisar.Repo.update!()

      conn = build_conn() |> bearer(raw) |> get(~p"/api/audit")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert is_nil(Emisar.Repo.reload!(key).last_used_at)
    end
  end

  # Setting up `Fixtures.Subjects.owner_subject` + `Fixtures.ApiKeys.create_api_key` audits
  # `account.created`, `user.signed_up`, `api_key.created` — so every
  # test starts with 3 baseline events on the account. We filter the
  # SIEM export to event types under our control to keep assertions
  # deterministic.
  @test_types ~w[user.signed_in user.signed_out policy.updated]
  defp event_type_query, do: Enum.map_join(@test_types, "&", &"event_type[]=#{&1}")

  describe "happy path" do
    test "returns NDJSON ordered ascending by (occurred_at, id)", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      _ = insert_event(account, "user.signed_in")
      _ = insert_event(account, "policy.updated")
      _ = insert_event(account, "user.signed_out")

      conn = conn |> bearer(raw) |> get("/api/audit?#{event_type_query()}")

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/x-ndjson"

      events = conn |> ndjson() |> parse_ndjson()
      assert length(events) == 3

      # Sorted ascending — first event is the oldest.
      assert Enum.map(events, & &1["event_type"]) ==
               ["user.signed_in", "policy.updated", "user.signed_out"]
    end

    test "includes the full row shape SIEMs ingest", %{conn: conn, account: account, raw_key: raw} do
      _ = insert_event(account, "policy.updated", payload: %{"changes" => %{"defaults" => %{}}})

      [event] =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=policy.updated")
        |> ndjson()
        |> parse_ndjson()

      assert event["id"]
      assert event["occurred_at"]
      assert event["account_id"] == account.id
      assert event["event_type"] == "policy.updated"
      assert event["actor_kind"] == "system"
      assert event["payload"]["changes"]["defaults"] == %{}
    end

    test "empty filter result is a 200 with no body and no next cursor", %{
      conn: conn,
      raw_key: raw
    } do
      # Filter to a type that has zero rows.
      conn = conn |> bearer(raw) |> get(~p"/api/audit?event_type=approval.expired")
      assert conn.resp_body == ""
      assert get_resp_header(conn, "x-next-cursor") == []
      assert get_resp_header(conn, "link") == []
    end
  end

  describe "pagination" do
    test "limit caps the page; cursor headers present on a full page", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      Enum.each(1..5, fn _ -> insert_event(account, "user.signed_in") end)

      conn = conn |> bearer(raw) |> get(~p"/api/audit?limit=2&event_type=user.signed_in")
      events = conn |> ndjson() |> parse_ndjson()

      assert length(events) == 2
      assert [cursor] = get_resp_header(conn, "x-next-cursor")
      assert cursor != ""
      assert [link] = get_resp_header(conn, "link")
      assert link =~ "<#{PublicUrl.url("/api/audit")}?"
      assert link =~ ~s(rel="next")
      assert link =~ "cursor=#{cursor}"
    end

    test "an over-cap limit still advertises the next page", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      # The served page is clamped to max_export_limit, so a caller asking for
      # more must still be told there is more. The delivered rows used to be
      # compared against the RAW parameter, so a full clamped page carried no
      # Link at all — and a conformant SIEM reads a missing Link as "caught up".
      # A full page is the only shape that discriminates, hence the bulk insert.
      cap = Audit.max_export_limit()
      Enum.each(1..(cap + 1), fn _ -> insert_event(account, "user.signed_in") end)

      conn =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?limit=#{cap + 500}&event_type=user.signed_in")

      assert length(conn |> ndjson() |> parse_ndjson()) == cap
      assert [link] = get_resp_header(conn, "link")
      assert link =~ ~s(rel="next")
    end

    test "a repeated event_type builds the next link instead of raising", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      # `?event_type[]=a&event_type[]=b` is the pinned-supported repeated form,
      # and it reaches the header builder as a list. URI.encode_query rejects
      # one, so building the Link raised and the response became a 500 — on the
      # exact path a SIEM catching up with a type filter takes.
      Enum.each(1..3, fn _ -> insert_event(account, "user.signed_in") end)

      conn =
        conn
        |> bearer(raw)
        |> get("/api/audit?limit=2&event_type[]=user.signed_in&event_type[]=user.signed_out")

      assert conn.status == 200
      assert [link] = get_resp_header(conn, "link")
      assert link =~ ~s(rel="next")
      assert link =~ "event_type"
    end

    test "?cursor=<…> resumes strictly after the prior page", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      all = Enum.map(1..5, fn _ -> insert_event(account, "user.signed_in") end)
      filter = "event_type=user.signed_in"

      first = conn |> bearer(raw) |> get("/api/audit?limit=2&#{filter}")
      [cursor] = get_resp_header(first, "x-next-cursor")
      first_ids = first |> ndjson() |> parse_ndjson() |> Enum.map(& &1["id"])

      second = conn |> bearer(raw) |> get("/api/audit?limit=2&#{filter}&cursor=#{cursor}")
      second_ids = second |> ndjson() |> parse_ndjson() |> Enum.map(& &1["id"])

      assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
      assert length(second_ids) == 2

      # The third page is the tail — one row, below the limit. Under keyset semantics it
      # STILL returns a resume cursor (so a re-poll can't re-read that row), but no
      # Link: rel="next", because there is nothing more right now.
      [cursor2] = get_resp_header(second, "x-next-cursor")
      third = conn |> bearer(raw) |> get("/api/audit?limit=2&#{filter}&cursor=#{cursor2}")
      third_ids = third |> ndjson() |> parse_ndjson() |> Enum.map(& &1["id"])

      assert length(third_ids) == 1
      assert [cursor3] = get_resp_header(third, "x-next-cursor")
      assert get_resp_header(third, "link") == []

      # Re-polling from the tail cursor returns nothing: the short page's row is not
      # double-counted, and now there are no headers at all (truly caught up).
      fourth = conn |> bearer(raw) |> get("/api/audit?limit=2&#{filter}&cursor=#{cursor3}")
      assert fourth |> ndjson() |> parse_ndjson() == []
      assert get_resp_header(fourth, "x-next-cursor") == []
      assert get_resp_header(fourth, "link") == []

      # Round-trip: every id surfaces exactly once across the 3 pages.
      assert Enum.sort(first_ids ++ second_ids ++ third_ids) ==
               all |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "limit beyond max is silently clamped to the hard cap", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      Enum.each(1..3, fn _ -> insert_event(account, "user.signed_in") end)

      # Asking for 99_999 still works — server caps to 1000.
      events =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?limit=99999&event_type=user.signed_in")
        |> ndjson()
        |> parse_ndjson()

      assert length(events) == 3
    end

    test "garbage limit param returns 400, not 500", %{conn: conn, raw_key: raw} do
      conn = conn |> bearer(raw) |> get(~p"/api/audit?limit=banana")
      body = json_response(conn, 400)
      assert body["error"] == "invalid_params"
      assert body["message"] =~ "limit"
    end

    test "malformed cursor returns 400, not silently rewinds", %{conn: conn, raw_key: raw} do
      conn = conn |> bearer(raw) |> get(~p"/api/audit?cursor=garbage")
      assert json_response(conn, 400)["error"] == "invalid_params"
    end

    test "a cursor with a non-UUID id returns 400 instead of an empty page", %{
      conn: conn,
      raw_key: raw
    } do
      cursor = Base.url_encode64("2026-01-01T00:00:00Z|not-a-uuid", padding: false)
      conn = conn |> bearer(raw) |> get("/api/audit?cursor=#{cursor}")

      assert json_response(conn, 400)["message"] =~ "cursor"
    end

    # a non-ISO8601 `since` is a 400 invalid_params, not a
    # 500 and never a silent fall-through to the whole-history scan. A SIEM that
    # sends a bad first-call bound is told to fix it, not handed everything.
    test "malformed since (non-ISO8601) returns 400, not a silent full scan", %{
      conn: conn,
      raw_key: raw
    } do
      conn = conn |> bearer(raw) |> get(~p"/api/audit?since=yesterday")
      body = json_response(conn, 400)
      assert body["error"] == "invalid_params"
      assert body["message"] =~ "ISO 8601"
    end
  end

  describe "filtering" do
    test "?event_type= restricts to a single type", %{conn: conn, account: account, raw_key: raw} do
      insert_event(account, "user.signed_in")
      insert_event(account, "policy.updated")
      insert_event(account, "user.signed_out")

      events =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=policy.updated")
        |> ndjson()
        |> parse_ndjson()

      assert length(events) == 1
      assert hd(events)["event_type"] == "policy.updated"
    end

    test "?event_type=a&event_type=b stacks (repeated param)", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      insert_event(account, "user.signed_in")
      insert_event(account, "policy.updated")
      insert_event(account, "user.signed_out")

      # Repeated param key — Plug parses to a list.
      events =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type[]=user.signed_in&event_type[]=user.signed_out")
        |> ndjson()
        |> parse_ndjson()

      assert Enum.map(events, & &1["event_type"]) |> Enum.sort() ==
               ["user.signed_in", "user.signed_out"]
    end

    test "?event_type=a,b CSV form also works", %{conn: conn, account: account, raw_key: raw} do
      insert_event(account, "user.signed_in")
      insert_event(account, "policy.updated")
      insert_event(account, "user.signed_out")

      events =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=user.signed_in,policy.updated")
        |> ndjson()
        |> parse_ndjson()

      assert Enum.map(events, & &1["event_type"]) |> Enum.sort() ==
               ["policy.updated", "user.signed_in"]
    end

    test "nested event_type params return 400 instead of raising", %{conn: conn, raw_key: raw} do
      conn = conn |> bearer(raw) |> get("/api/audit?event_type[unexpected]=policy.updated")

      assert json_response(conn, 400)["message"] =~ "event_type"
    end
  end

  describe "cross-account isolation" do
    test "an audit-export key only sees its own account's events", %{
      conn: conn,
      account: own_account,
      raw_key: raw
    } do
      # Build a separate account with its own events. The bearer-auth'd
      # key here belongs to `own_account` and must NEVER see the other.
      {other_user, other_account, _other_subject} = Fixtures.Subjects.owner_subject()
      _ = other_user

      insert_event(own_account, "user.signed_in")
      insert_event(other_account, "user.signed_in")

      events =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=user.signed_in")
        |> ndjson()
        |> parse_ndjson()

      assert length(events) == 1
      assert hd(events)["account_id"] == own_account.id
    end

    # a forged `x-forwarded-for` is advisory request
    # metadata only: it never feeds authz or scoping. The export stays scoped to
    # the key's own account (`for_subject/2`), so spoofing the header can't widen
    # the result set or reach another tenant's events. (Plug.RemoteIp isn't in
    # the pipeline; the spoofable header is a documented trade-off, used for the
    # advisory IP column, not an access-control input.)
    test "a spoofed x-forwarded-for header does not affect scoping", %{
      conn: conn,
      account: own_account,
      raw_key: raw
    } do
      other_account = Fixtures.Accounts.create_account()

      insert_event(own_account, "user.signed_in")
      insert_event(other_account, "user.signed_in")

      events =
        conn
        |> bearer(raw)
        |> put_req_header("x-forwarded-for", "203.0.113.255, 10.0.0.1")
        |> get(~p"/api/audit?event_type=user.signed_in")
        |> ndjson()
        |> parse_ndjson()

      # Still only the key's own account — the forged header changed nothing.
      assert length(events) == 1
      assert hd(events)["account_id"] == own_account.id
    end
  end

  describe "serialized row shape" do
    test "strips hostile metadata from historical rows", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      _event =
        %Audit.Event{
          account_id: account.id,
          occurred_at: DateTime.utc_now(),
          event_type: "audit.test.historical",
          actor_kind: "system"
        }
        |> Ecto.Changeset.change(
          ip_address: "203.0." <> <<27>> <> "113.7",
          user_agent: "agent\u202Etxt",
          request_id: "req\u200D123"
        )
        |> Repo.insert!()

      [event] =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=audit.test.historical")
        |> ndjson()
        |> parse_ndjson()

      assert event["ip_address"] == "203.0.113.7"
      assert event["user_agent"] == "agenttxt"
      assert event["request_id"] == "req123"
    end

    test "exports the run's dispatch and policy evidence separately from its terminal reason", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      run = Fixtures.Runs.create_run(account_id: account.id, status: :success)
      policy_id = Ecto.UUID.generate()

      audited_run = %{
        run
        | reason: "Check production load",
          reason_text: "runner completed",
          policy_id: policy_id,
          policy_decision: "allow",
          policy_reason: "Matched the production safety rule",
          policy_version: 7,
          matched_rules: ["production-safety"]
      }

      {:ok, _event} = Audit.record(Audit.run_event_changeset(audited_run))

      [event] =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=action_run.success")
        |> ndjson()
        |> parse_ndjson()

      assert event["payload"]["dispatch_reason"] == "Check production load"
      assert event["payload"]["policy_id"] == policy_id
      assert event["payload"]["policy_decision"] == "allow"
      assert event["payload"]["policy_reason"] == "Matched the production safety rule"
      assert event["payload"]["policy_version"] == 7
      assert event["payload"]["matched_rules"] == ["production-safety"]
      assert event["payload"]["reason"] == "runner completed"
    end

    test "omits auth_method / mfa / user_identity_id from the feed", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      # These columns exist on the audit row (surfaced in the UI detail
      # view) but are deliberately NOT projected into the SIEM feed.
      _ =
        insert_event(account, "user.signed_in",
          auth_method: "sso",
          mfa: true,
          user_identity_id: Ecto.UUID.generate()
        )

      [event] =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=user.signed_in")
        |> ndjson()
        |> parse_ndjson()

      # The projected columns are present; these UI-only ones are absent.
      assert event["event_type"] == "user.signed_in"
      refute Map.has_key?(event, "auth_method")
      refute Map.has_key?(event, "mfa")
      refute Map.has_key?(event, "user_identity_id")
    end

    test "promotes self-reported MCP client metadata to a stable top-level field", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      # A SIEM correlates on asset_tag/device_id without digging into the nested
      # payload, so the run event's metadata is projected to a top-level field.
      metadata = %{"asset_tag" => "LT-4417", "device_id" => "d-99"}

      _ =
        insert_event(account, "action_run.success",
          target_kind: "runner",
          payload: %{"run_id" => Ecto.UUID.generate(), "mcp_client_metadata" => metadata}
        )

      [event] =
        conn
        |> bearer(raw)
        |> get(~p"/api/audit?event_type=action_run.success")
        |> ndjson()
        |> parse_ndjson()

      assert event["mcp_client_metadata"] == metadata
      # Still available inside the full payload too.
      assert event["payload"]["mcp_client_metadata"] == metadata
    end
  end

  describe "credential kind independence" do
    test "an audit-export key can export but is refused on the MCP surface", %{
      conn: conn,
      account: account,
      raw_key: raw
    } do
      _ = insert_event(account, "user.signed_in")

      # The log-shipping key exports fine — 200 NDJSON.
      export = conn |> bearer(raw) |> get(~p"/api/audit?event_type=user.signed_in")
      assert export.status == 200
      assert [_ | _] = export |> ndjson() |> parse_ndjson()

      # The same key is refused at the MCP tool boundary, so a leaked SIEM key
      # cannot read the catalog or execute an action.
      request = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"})

      body =
        build_conn()
        |> bearer(raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/rpc", request)
        |> json_response(200)

      assert body["error"]["code"] == -32_002
      assert body["error"]["data"]["required"] == "mcp"
    end
  end

  describe "self-logs exports (watch the watchers)" do
    test "a non-empty page writes one audit.exported row attributed to the api_key", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: account.id,
          created_by_id: subject.actor.id,
          kind: :audit_export
        )

      _ = insert_event(account, "user.signed_in")
      _ = insert_event(account, "user.signed_in")

      # Filter to just those two so the marker's count is deterministic no matter
      # what rows the account fixtures wrote.
      conn = conn |> bearer(raw) |> get(~p"/api/audit?event_type=user.signed_in")
      assert length(parse_ndjson(ndjson(conn))) == 2

      assert [marker] = export_markers(subject)
      assert marker.actor_kind == "api_key"
      assert marker.actor_id == key.id
      assert marker.payload["count"] == 2
    end

    test "a caught-up poll (0 rows) writes nothing — no self-spam", %{
      conn: conn,
      subject: subject,
      raw_key: raw
    } do
      # A future `since` guarantees an empty page regardless of pre-existing rows,
      # so a forward-cursor poll that's caught up writes no marker.
      conn = conn |> bearer(raw) |> get("/api/audit?since=2999-01-01T00:00:00Z")
      assert response(conn, 200) == ""

      assert export_markers(subject) == []
    end

    test "the export marker is account-scoped — another account never sees it", %{
      conn: conn,
      account: account,
      subject: subject,
      raw_key: raw
    } do
      _ = insert_event(account, "user.signed_in")
      _ = conn |> bearer(raw) |> get(~p"/api/audit?event_type=user.signed_in")

      # This account logged exactly one export marker…
      assert [_] = export_markers(subject)

      # …and a different account's owner sees none of it.
      {_ub, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert export_markers(subject_b) == []
    end
  end
end
