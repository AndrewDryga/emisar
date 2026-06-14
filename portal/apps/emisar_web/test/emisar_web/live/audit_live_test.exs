defmodule EmisarWeb.AuditLiveTest do
  @moduledoc """
  Smoke-tests the redesigned audit list + detail. Confirms IP column
  shows, subject labels are looked up live (so a renamed runner is
  reflected on next page load), the row links to a detail page, and
  the detail page renders payload + headers without crashing.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Audit, Repo}
  alias Emisar.Runners.Runner

  describe "GET /app/audit" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/audit")
    end

    test "renders rows with IP + a link into the subject's detail page", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Make a runner so we have a real subject to look up.
      {:ok, runner} =
        Runner.Changeset.register(%{
          account_id: account.id,
          name: "db-prod-01",
          external_id: Ecto.UUID.generate(),
          group: "default",
          hostname: "10.0.5.12",
          runner_version: "0.1.0"
        })
        |> Repo.insert()

      {:ok, _event} =
        Audit.log(account.id, "runner.connected",
          actor_kind: "runner",
          actor_id: runner.id,
          actor_label: runner.name,
          subject_kind: "runner",
          subject_id: runner.id,
          subject_label: runner.name,
          ip_address: "10.0.5.12",
          user_agent: "emisar-runner/0.1.0"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/audit")

      assert html =~ "runner.connected"
      assert html =~ "10.0.5.12"
      assert html =~ "db-prod-01"
      assert html =~ ~p"/app/runners/#{runner.id}"
      # Subject/IP columns collapse below lg so the table fits a phone.
      assert html =~ "hidden lg:table-cell"
    end

    test "rows carry an outcome dot — rose for failures, amber for denials, neutral for routine",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      for {type, subject_kind} <- [
            {"user.sign_in_failed", "user"},
            {"approval.denied", "approval_request"},
            {"runner.connected", "runner"}
          ] do
        {:ok, _} = Audit.log(account.id, type, subject_kind: subject_kind, subject_label: "x")
      end

      {:ok, _lv, html} = live(conn, ~p"/app/audit")

      assert html =~ "bg-rose-400"
      assert html =~ "bg-amber-400"
      assert html =~ "bg-zinc-700"
    end

    test "label updates reflect on next load (no stale snapshot)", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, runner} =
        Runner.Changeset.register(%{
          account_id: account.id,
          name: "old-name",
          external_id: Ecto.UUID.generate(),
          group: "default",
          runner_version: "0.1.0"
        })
        |> Repo.insert()

      {:ok, _event} =
        Audit.log(account.id, "runner.touched",
          subject_kind: "runner",
          subject_id: runner.id,
          subject_label: "old-name"
        )

      # Rename. The audit row still says "old-name" in subject_label.
      runner
      |> Ecto.Changeset.change(name: "renamed-prod")
      |> Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/app/audit")

      # The live label takes precedence over the snapshot.
      assert html =~ "renamed-prod"
    end

    test "the actor links into a filtered audit view, and the date form renders", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: actor_id,
          actor_label: "alice@example.com"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/audit")

      # The actor value links to "what did this identity do", not its
      # resource page.
      assert html =~ "/app/audit?actor_id=#{actor_id}"
      assert html =~ "From (UTC)"
      assert html =~ "To (UTC)"
      # The free-text trace filter (paste a request_id/type) is wired in.
      assert html =~ "Search (type or request id)"
      assert html =~ ~s(name="q")
    end

    test "a relative date preset narrows to recent events without UTC math", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Distinct actor_labels — event_type alone also appears in the filter
      # dropdown, so it can't tell a row apart from an option.
      {:ok, old} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "ancient-actor"
        )

      old
      |> Ecto.Changeset.change(occurred_at: DateTime.add(DateTime.utc_now(), -259_200, :second))
      |> Emisar.Repo.update!()

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "fresh-actor"
        )

      {:ok, lv, html} = live(conn, ~p"/app/audit")
      assert html =~ "Last 24h"
      assert html =~ "ancient-actor"

      # "Last 24h" patches to a from-bound; mounting it drops the 3-day-old one.
      render_click(lv, "preset_range", %{"window" => "24h"})
      to = assert_patch(lv)
      assert to =~ "from="

      {:ok, _lv2, html} = live(conn, to)
      assert html =~ "fresh-actor"
      refute html =~ "ancient-actor"
    end

    test "filtering by actor_id narrows the list and shows a clearable chip", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_a = Ecto.UUID.generate()
      actor_b = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: actor_a,
          actor_label: "alice"
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: actor_b,
          actor_label: "bob"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/audit?actor_id=#{actor_a}")

      assert html =~ "Actor:"
      assert html =~ "alice"
      # bob's event is filtered out entirely.
      refute html =~ "bob"
    end

    test "selecting an actor kind surfaces a picker of that kind's resolved actors",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_id: user.id)

      # No kind selected → no actor picker rendered.
      {:ok, _lv, html} = live(conn, ~p"/app/audit")
      refute html =~ ~s(name="actor_id")

      # One kind selected → the picker appears, listing the resolved actor.
      {:ok, _lv, html} = live(conn, ~p"/app/audit?actor_kind=user")
      assert html =~ ~s(name="actor_id")
      assert html =~ ~s(value="#{user.id}")
      # …and right after its Actor-type trigger — before the next (Subject)
      # filter, not tacked on at the end.
      assert :binary.match(html, ~s(name="actor_id")) <
               :binary.match(html, ~s(name="subject_kind"))

      assert html =~ user.email
    end
  end

  describe "GET /app/audit/:id" do
    test "renders the full payload + IP + UA", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, event} =
        Audit.log(account.id, "api_key.created",
          actor_kind: "user",
          actor_label: "owner@example.com",
          subject_kind: "api_key",
          subject_label: "ci-bot",
          ip_address: "203.0.113.7",
          user_agent: "Mozilla/5.0 (Macintosh)",
          payload: %{prefix: "emk-abcdef", scopes: ["actions:read", "actions:execute"]}
        )

      {:ok, _lv, html} = live(conn, ~p"/app/audit/#{event.id}")

      assert html =~ "api_key.created"
      assert html =~ "203.0.113.7"
      assert html =~ "Mozilla/5.0 (Macintosh)"
      assert html =~ "actions:execute"
      assert html =~ "owner@example.com"
      # Subject of kind api_key links to the agents page (where keys live).
      assert html =~ ~p"/app/agents"
    end

    test "parses bridge user agent into client + host + os posture fields", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, event} =
        Audit.log(account.id, "linux.uptime.run",
          actor_kind: "api_key",
          actor_label: "Claude Desktop",
          subject_kind: "action_run",
          subject_label: "linux.uptime",
          ip_address: "127.0.0.1",
          user_agent: "emisar-mcp/dev (client=claude-desktop; host=andrews-mbp.local; os=darwin)"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/audit/#{event.id}")

      assert html =~ "claude-desktop"
      assert html =~ "andrews-mbp.local"
      # The host's OS, parsed from the same UA posture block.
      assert html =~ "darwin"
      assert html =~ "emisar-mcp/dev"
      # The raw UA is still shown below the cards for forensics.
      assert html =~ "emisar-mcp/dev (client=claude-desktop"
    end

    test "shows the MCP session id when the event carries one", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, event} =
        Audit.log(account.id, "action_run.success",
          actor_kind: "api_key",
          actor_label: "Claude Code",
          subject_kind: "action_run",
          subject_label: "nomad.job_status",
          ip_address: "127.0.0.1",
          user_agent: "emisar-mcp/0.1.1 (client=claude-code; host=mac)",
          mcp_session_id: "5985d95cf73715ff"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/audit/#{event.id}")

      assert html =~ "MCP session"
      assert html =~ "5985d95cf73715ff"
    end

    test "redirects to list with flash when event id is unknown", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      missing = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/app/audit"}}} =
               live(conn, ~p"/app/audit/#{missing}")
    end

    test "events from other accounts 404 (account scoping)", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)

      # Brand-new account the logged-in user has no membership in.
      other = Emisar.Fixtures.account_fixture()

      {:ok, event} = Audit.log(other.id, "secret.event", actor_kind: "system")

      assert {:error, {:live_redirect, %{to: "/app/audit"}}} =
               live(conn, ~p"/app/audit/#{event.id}")
    end
  end

  describe "SIEM export keys" do
    test "mint shows the secret once, list updates, revoke retires it", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Emisar.Fixtures.subject_for(user, account)
      {:ok, lv, _html} = live(conn, ~p"/app/audit")

      # Mint: the raw emk- secret is rendered exactly once.
      html = render_click(lv, "create_export_key", %{})
      assert html =~ "emk-"
      assert html =~ "Audit export —"

      html = render_click(lv, "dismiss_export_secret", %{})
      refute html =~ "emk-NOSUCH"

      # The minted key row is in the export list; revoke it.
      {:ok, [key], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      html = render_click(lv, "revoke_export_key", %{"id" => key.id})
      assert html =~ "Export token revoked."

      # Revoked keys stay listed (audit trail) but carry the revocation.
      {:ok, [revoked], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      assert revoked.revoked_at
    end

    test "a viewer cannot mint an export key", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)

      viewer = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/audit")

      html = render_click(lv, "create_export_key", %{})
      assert html =~ "You don&#39;t have permission to do that."
      refute html =~ "emk-"
    end

    test "an api_key list_changed broadcast refreshes the key list", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/audit")

      # A key minted elsewhere (another tab/admin) appears via the broadcast.
      subject = Emisar.Fixtures.subject_for(user, account)

      {:ok, _raw, key} =
        Emisar.ApiKeys.create_key(
          %{name: "Side-channel export", scopes: ["audit:read"]},
          subject
        )

      send(lv.pid, {:list_changed, :api_key, "api_key.created", key.id})
      assert render(lv) =~ "Side-channel export"
    end
  end
end
