defmodule EmisarWeb.AgentsLiveTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.ApiKeys
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Repo

  describe "GET /app/agents" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/agents")
    end

    test "mount renders the client picker but does NOT auto-mint a key", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/agents")

      assert html =~ "LLM agents"
      assert html =~ "Pick a client above to get started"

      # All client tiles are rendered.
      assert html =~ "Claude.ai"
      assert html =~ "ChatGPT"
      assert html =~ "Claude Code"
      assert html =~ "Claude Desktop"
      assert html =~ "Cursor"
      assert html =~ "Gemini CLI"
      assert html =~ "Codex CLI"

      # No key minted until a client is picked.
      assert Repo.all(ApiKey) == []
      refute html =~ "EMISAR_API_KEY"
    end

    test "the list has status/name filters + the custom panel states the capability",
         %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/agents")

      # Part b — the list filter bar (always rendered).
      assert html =~ "Name contains"
      assert html =~ "Status"

      # Part a — the capability copy appears once the operator opens the
      # custom-key form (it's behind the "custom" client tab).
      custom = render_click(lv, "select_client", %{"client" => "custom"})
      assert custom =~ "read and execute every action"
    end

    test "selecting Claude.ai (remote MCP) shows URL + bearer header instead of bridge snippet",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/agents")

      html = lv |> render_click("select_client", %{"client" => "claude_web"})

      # Mint still happens — same flow, just remote transport.
      [auto] = Repo.all(ApiKey)
      assert auto.account_id == account.id
      assert auto.name == "Claude.ai"

      # Remote-MCP UI is shown:
      assert html =~ "/api/mcp/rpc"
      assert html =~ "Authorization: Bearer emk-"
      assert html =~ "Steps for Claude.ai"
      # The reveal reads as a new live credential, not setup copy.
      assert html =~ "New key minted"
      assert html =~ "Settings &rarr; Connectors" or html =~ "Settings → Connectors"

      # The local-bridge snippet shape is NOT shown for this client.
      refute html =~ "EMISAR_API_KEY"
      refute html =~ "/usr/local/bin/emisar-mcp"

      # The install-emisar-mcp block does not render at all for remote
      # MCP clients — it's a local-bridge-only concern.
      refute html =~ "install-mcp.sh"
      refute html =~ "Install the bridge"
    end

    test "selecting ChatGPT shows the remote MCP panel too", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/agents")

      html = lv |> render_click("select_client", %{"client" => "chatgpt"})

      [auto] = Repo.all(ApiKey)
      assert auto.name == "ChatGPT"
      assert html =~ "/api/mcp/rpc"
      assert html =~ "Steps for ChatGPT"
    end

    test "selecting a client mints a key named after the client + inlines snippet", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/agents")

      html = lv |> render_click("select_client", %{"client" => "claude_desktop"})

      # The mint happened.
      [auto] = Repo.all(ApiKey)
      assert auto.account_id == account.id
      assert auto.name == "Claude Desktop"
      assert ApiKey.auto_unused?(auto)

      # Snippet shows the bridge config with EMISAR_CLIENT stamped so
      # the cloud audit can attribute calls back to this client.
      assert html =~ "EMISAR_API_KEY"
      assert html =~ "EMISAR_CLIENT"
      assert html =~ "claude-desktop"
      assert html =~ "emk-"
      assert html =~ "New key minted"

      # Auto-unused — operator's list is still empty until an MCP call
      # promotes it.
      assert {:ok, [], _} = ApiKeys.list_api_keys_for_account(owner_subject(user, account))
    end

    test "an MCP call promotes the picked-key to a visible Connected LLM", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/agents")

      html = lv |> render_click("select_client", %{"client" => "claude_code"})

      [_, raw] = Regex.run(~r/EMISAR_API_KEY=(emk-[A-Za-z0-9_-]+)/, html)
      [%ApiKey{} = auto] = Repo.all(ApiKey)
      assert auto.name == "Claude Code"

      promoted = ApiKeys.peek_api_key_by_secret(raw)
      assert promoted.id == auto.id
      assert is_nil(promoted.auto_generated_at)
      assert promoted.last_used_at != nil

      assert {:ok, [%ApiKey{id: id}], _} =
               ApiKeys.list_api_keys_for_account(owner_subject(user, account))

      assert id == auto.id
    end

    test "agents list shows the creator's email", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _raw, _key} =
        ApiKeys.create_key(
          %{
            name: "manual-bot",
            scopes: ["actions:read"],
            runner_filter: []
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/agents")

      assert html =~ "manual-bot"
      assert html =~ user.email
    end

    test "agents list shows the MCP client a key reported (clientInfo)", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _raw, key} =
        ApiKeys.create_key(
          %{name: "prod-mcp", scopes: ["actions:execute"], runner_filter: []},
          subject
        )

      {:ok, _} =
        ApiKeys.record_client_info(key, %{
          "name" => "claude-code",
          "title" => "Claude Code",
          "version" => "1.2.3"
        })

      {:ok, _lv, html} = live(conn, ~p"/app/agents")

      # The reported client shows even though the key is named generically —
      # it's the actual client. The human "title" is preferred over the
      # machine "name", with the version appended.
      assert html =~ "Claude Code 1.2.3"
      refute html =~ "claude-code 1.2.3"
    end

    test "status badge derives from last_used_at", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      # Active: last_used 2 min ago
      {:ok, _, active} =
        ApiKeys.create_key(
          %{
            name: "ActiveBot",
            scopes: ["actions:read"],
            runner_filter: []
          },
          subject
        )

      active
      |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(), -120, :second))
      |> Repo.update!()

      # Idle: last_used 2 h ago
      {:ok, _, idle} =
        ApiKeys.create_key(
          %{
            name: "IdleBot",
            scopes: ["actions:read"],
            runner_filter: []
          },
          subject
        )

      idle
      |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second))
      |> Repo.update!()

      # Never used: leave last_used_at nil
      {:ok, _, _never} =
        ApiKeys.create_key(
          %{
            name: "NeverBot",
            scopes: ["actions:read"],
            runner_filter: []
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/agents")

      assert html =~ "Active</span>" or html =~ "Active\n"
      assert html =~ "Idle"
      assert html =~ "Never used"
      # Stat counters: 1 active, 1 idle, 1 never_used
      assert html =~ "ActiveBot"
      assert html =~ "IdleBot"
      assert html =~ "NeverBot"
    end

    test "custom-key form shows validation errors inline on the field, not in a flash",
         %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/agents")

      # The custom-key builder form only renders after the Custom tab is
      # picked (no quick-mint on that tab).
      lv |> render_click("select_client", %{"client" => "custom"})

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => ""}})
        |> render_submit()

      # Inline field error rendered by <.input>/<.error> under the name
      # input…
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      # …and no flash banner dumping a humanized changeset.
      refute html =~ "Could not create key"
      # No key was persisted on the invalid submit.
      assert Repo.all(ApiKey) == []
    end

    test "survives an account-topic broadcast it doesn't render", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/agents")

      # The pending-badge hooks subscribe every authenticated LV to the
      # account's approvals/packs topics and forward those broadcasts.
      # This page renders neither — it must absorb the message, not crash.
      send(lv.pid, {:approval_updated, %{id: Ecto.UUID.generate()}})

      assert render(lv) =~ "LLM agents"
    end
  end
end
