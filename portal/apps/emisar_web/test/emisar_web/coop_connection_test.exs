defmodule EmisarWeb.CoopConnectionTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{ApiKeys, Repo}
  alias Emisar.ApiKeys.ApiKey
  alias EmisarWeb.AgentClientConfig

  test "co:op defaults to an HTTP entry that keeps the key out of the box" do
    config = AgentClientConfig.render("coop", "https://example.test", "emk-example", :macos, "")

    assert Jason.decode!(config.body)["mcpServers"]["emisar"] == %{
             "type" => "http",
             "url" => "https://example.test/api/mcp/rpc",
             "bearer_token_env_var" => "EMISAR_MCP_TOKEN"
           }

    refute config.body =~ "emk-example"
    assert config.env == "EMISAR_MCP_TOKEN=emk-example"
  end

  test "the co:op bridge alternative gets its rule and durable credential storage" do
    config = AgentClientConfig.render("coop", "https://example.test", "emk-example", :macos, "")
    server = Jason.decode!(config.bridge_body)["mcpServers"]["emisar"]

    assert AgentClientConfig.coop_egress_rule("https://example.test") == """
           box:
             egress_rules:
               - to: {domain: "example.test"}
                 protocol: tls
                 ports: [443]
           """

    assert server == %{
             "command" => "/usr/local/bin/emisar-mcp",
             "env" => %{
               "EMISAR_URL" => "https://example.test",
               "EMISAR_API_KEY" => "emk-example",
               "EMISAR_CLIENT" => "coop",
               "XDG_CONFIG_HOME" => "/config"
             }
           }
  end

  test "the public sandbox guide is discoverable and documents the co:op boundary", %{
    conn: conn
  } do
    html = conn |> get(~p"/docs/connect-agent-sandboxes") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query("h1") |> LazyHTML.text() |> String.trim() ==
             "Agent sandboxes"

    assert doc |> LazyHTML.query("h2#coop") |> Enum.count() == 1
    assert html =~ ~s(href="/app/agents/connect")
    assert html =~ ~s(href="/app/audit")
    assert html =~ ".coopignore"
    assert html =~ "box.egress_rules"
    assert html =~ "lasts 30 days"
    assert html =~ "signed dispatch"
    refute html =~ "whole internet"
    refute html =~ "box.egress: filtered"
    refute html =~ "EMISAR_API_KEY"
    refute html =~ "COOP_RUNTIME="
    refute html =~ "install-mcp.sh"

    for path <- ~w(/docs /docs/quickstart /docs/connect-cli-agent /sitemap.xml) do
      assert conn |> get(path) |> response(200) =~ "/docs/connect-agent-sandboxes"
    end
  end

  test "co:op shows its configuration on selection and keeps one member-bound key", %{
    conn: conn
  } do
    {conn, owner, account} = register_and_log_in(conn)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/agents/connect")
    assert Repo.all(ApiKey) == []
    render_click(lv, "select_client", %{"client" => "coop"})

    assert has_element?(lv, "p", "Agent sandboxes")
    refute has_element?(lv, "p", "Agent containers")
    assert has_element?(lv, "#coop-version", "coop version")

    assert has_element?(
             lv,
             "#coop-install-step a[href='https://github.com/AndrewDryga/coop#install']",
             "official installation guide"
           )

    assert has_element?(lv, "#coop-limits", "Setup recommendations")
    refute has_element?(lv, "#coop-tool-prompts")
    assert has_element?(lv, "#coop-start", "coop codex")
    refute has_element?(lv, "#install-mcp-cmd")
    assert has_element?(lv, "#coop-config")
    refute has_element?(lv, "#coop-config-step details #coop-config")
    refute has_element?(lv, "#coop-config-step details #coop-env")
    refute has_element?(lv, "#coop-config-step button[phx-click]")
    [key] = Repo.all(ApiKey)
    assert key.name == "co:op"
    assert key.account_id == account.id
    assert key.created_by_membership_id == Fixtures.Subjects.subject_for(owner).membership_id

    entry = lv |> panel_text("#coop-config") |> Jason.decode!()
    assert entry["mcpServers"]["emisar"]["url"] =~ "/api/mcp/rpc"
    assert entry["mcpServers"]["emisar"]["bearer_token_env_var"] == "EMISAR_MCP_TOKEN"

    assert "EMISAR_MCP_TOKEN=" <> raw = panel_text(lv, "#coop-env")
    assert raw =~ "emk-"

    bridge = lv |> panel_text("#coop-bridge-config") |> Jason.decode!()
    assert bridge["mcpServers"]["emisar"]["command"] == "/usr/local/bin/emisar-mcp"
    assert bridge["mcpServers"]["emisar"]["env"]["EMISAR_API_KEY"] == raw
    assert bridge["mcpServers"]["emisar"]["env"]["XDG_CONFIG_HOME"] == "/config"

    assert render_click(lv, "select_client", %{"client" => "coop"}) =~ raw
    assert Repo.all(ApiKey) == [key]

    assert %ApiKey{id: key_id} = ApiKeys.peek_api_key_by_secret(raw)
    assert key_id == key.id
    # The key-event reload is debounced; run it now.
    render(lv)
    send(lv.pid, :reload_agents)
    assert render(lv) =~ "Agent connected"
    assert has_element?(lv, "#agent-connection-status[data-state='connected']")

    render_click(lv, "select_client", %{"client" => "codex"})
    refute render(lv) =~ raw
  end

  test "co:op setup shows the complete procedure and filled configuration together", %{conn: conn} do
    {conn, _owner, account} = register_and_log_in(conn)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/agents/connect")
    render_click(lv, "select_client", %{"client" => "coop"})

    assert has_element?(lv, "#coop-install-step", "Make sure co:op is installed")
    assert has_element?(lv, "#coop-version", "coop version")
    refute render(lv) =~ "raw.githubusercontent.com/AndrewDryga/coop/main/install.sh"

    init_commands =
      lv
      |> element("#coop-init")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert init_commands == "coop init\ncoop login codex"
    assert has_element?(lv, "#coop-config-step", "Add emisar to co:op")
    assert has_element?(lv, "#coop-config-step", "~/.config/coop/agents/mcp.json")
    assert has_element?(lv, "#coop-config-step", "~/.config/coop/agents/env")
    assert has_element?(lv, "#coop-key-renewal", "lasts 30 days")

    # The default path changes neither the image nor the network rules, so all of
    # that stays inside the bridge alternative.
    assert has_element?(lv, "#coop-bridge", "signed dispatch")
    refute has_element?(lv, "#coop-bridge[open]")
    assert has_element?(lv, "#coop-bridge #coop-dockerfile")
    assert has_element?(lv, "#coop-bridge #coop-storage")

    assert has_element?(
             lv,
             "#coop-bridge #coop-build",
             "coop approve && coop build && coop doctor"
           )

    assert panel_text(lv, "#coop-egress-rule") =~ ~s(- to: {domain: "www.example.com"})
    assert has_element?(lv, "#coop-bridge", "~/.config/coop/coop.conf")

    storage_settings =
      lv
      |> element("#coop-storage")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert storage_settings == "COOP_RUN_ARGS=-v coop-emisar-config:/config"
    refute render(lv) =~ "COOP_RUNTIME="

    assert has_element?(lv, "#agent-connect-step", "3")
    assert has_element?(lv, "#agent-example-prompt", "linux.uptime")
    assert has_element?(lv, "#agent-connect-step a[href='/app/#{account.slug}/audit']", "Audit")
    assert has_element?(lv, "#coop-config")

    dockerfile =
      lv
      |> element("#coop-dockerfile")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert dockerfile =~ "FROM ${COOP_BASE_IMAGE}"

    assert dockerfile =~ "curl -fsSL https://emisar.dev/install-mcp.sh | bash -s -- --yes"
    assert dockerfile =~ "emisar-mcp --version"

    assert dockerfile =~ "install -d -m 700 -o node -g node /config"
  end

  test "a viewer cannot mint a co:op key through forged events", %{conn: conn} do
    account = Fixtures.Accounts.create_account()

    viewer = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

    {:ok, lv, _} = conn |> log_in_member(viewer) |> live(~p"/app/#{account}/agents/connect")

    assert render_click(lv, "select_client", %{"client" => "coop"}) =~
             "You don&#39;t have permission to do that."

    assert render_click(lv, "reveal_snippet", %{}) =~ "You don&#39;t have permission to do that."
    assert Repo.all(ApiKey) == []
    refute has_element?(lv, "#coop-config")
  end

  test "an operator's automatic key stays in the current account despite forged scope", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    other_account = Fixtures.Accounts.create_account()

    operator = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

    {:ok, lv, _} = conn |> log_in_member(operator) |> live(~p"/app/#{account}/agents/connect")

    render_click(lv, "select_client", %{"client" => "coop", "account_id" => other_account.id})

    assert has_element?(lv, "#coop-config")
    [key] = Repo.all(ApiKey)
    assert key.account_id == account.id
    assert key.created_by_membership_id == operator.id
  end

  test "failed configuration preparation stays inline and can be retried", %{conn: conn} do
    {conn, owner, account} = register_and_log_in(conn)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/agents/connect")
    downgraded = Fixtures.Memberships.force_role(owner, "viewer")

    render_click(lv, "select_client", %{"client" => "coop"})

    assert Repo.all(ApiKey) == []
    assert has_element?(lv, "#coop-config-error", "Couldn't prepare the configuration.")
    refute has_element?(lv, "#coop-config")

    Fixtures.Memberships.force_role(downgraded, "owner")
    lv |> element("#coop-config-error button", "Try again") |> render_click()

    assert has_element?(lv, "#coop-config")
    refute has_element?(lv, "#coop-config-error")
    assert [%ApiKey{}] = Repo.all(ApiKey)
  end

  defp panel_text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("pre")
    |> LazyHTML.text()
    |> String.trim()
  end
end
