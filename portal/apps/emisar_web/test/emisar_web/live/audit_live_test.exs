defmodule EmisarWeb.AuditLiveTest do
  @moduledoc """
  Smoke-tests the redesigned audit list + detail. Confirms IP column
  shows, subject labels are looked up live (so a renamed runner is
  reflected on next page load), the row links to a detail page, and
  the detail page renders payload + headers without crashing.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, Audit, Repo}
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
      {:ok, other} =
        Accounts.create_account(%{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}",
          plan: "free"
        })

      {:ok, event} = Audit.log(other.id, "secret.event", actor_kind: "system")

      assert {:error, {:live_redirect, %{to: "/app/audit"}}} =
               live(conn, ~p"/app/audit/#{event.id}")
    end
  end
end
