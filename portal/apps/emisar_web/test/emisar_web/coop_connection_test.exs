defmodule EmisarWeb.CoopConnectionTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{ApiKeys, Repo}
  alias Emisar.ApiKeys.ApiKey
  alias EmisarWeb.AgentClientConfig

  test "co:op gets one container bridge configuration with durable credential storage" do
    config = AgentClientConfig.render("coop", "https://example.test", "emk-example", :macos, "")
    server = Jason.decode!(config.body)["mcpServers"]["emisar"]

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

  test "the public walkthrough is discoverable and documents the container boundary", %{
    conn: conn
  } do
    html = conn |> get(~p"/docs/connect-coop") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query("h1") |> LazyHTML.text() |> String.trim() == "co:op"
    assert html =~ ~s(href="/app/agents/connect")
    assert html =~ ~s(href="/app/audit")
    assert html =~ "Copy the MCP configuration"
    refute html =~ "Create co:op configuration"
    assert html =~ "/usr/local/bin/emisar-mcp"
    assert html =~ "COOP_RUN_ARGS=-v coop-emisar-config:/config"
    assert html =~ "XDG_CONFIG_HOME"
    assert html =~ "EMISAR_SIGNING_KEY"

    assert html =~ "curl -fsSL https://emisar.dev/install-mcp.sh | bash -s -- --yes"

    refute html =~ "GitHub CLI"
    refute html =~ "/tmp/install-mcp.sh"

    for path <- ~w(/docs /docs/quickstart /docs/connect-cli-agent /sitemap.xml) do
      assert conn |> get(path) |> response(200) =~ "/docs/connect-coop"
    end
  end

  test "co:op shows its configuration on selection and keeps one member-bound key", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/agents/connect")
    assert Repo.all(ApiKey) == []
    render_click(lv, "select_client", %{"client" => "coop"})

    assert has_element?(lv, "p", "Agent sandboxes")
    refute has_element?(lv, "p", "Agent containers")
    assert has_element?(lv, "#coop-install")
    assert has_element?(lv, "#coop-start", "coop codex")
    refute has_element?(lv, "#install-mcp-cmd")
    assert has_element?(lv, "#coop-config")
    refute has_element?(lv, "#coop-config-step details")
    refute has_element?(lv, "#coop-config-step button[phx-click]")
    [key] = Repo.all(ApiKey)
    assert key.name == "co:op"
    assert key.account_id == account.id
    assert key.created_by_membership_id == owner_subject(user, account).membership_id

    config =
      lv
      |> element("#coop-config")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("pre")
      |> LazyHTML.text()
      |> Jason.decode!()

    raw = config["mcpServers"]["emisar"]["env"]["EMISAR_API_KEY"]
    assert raw =~ "emk-"
    assert config["mcpServers"]["emisar"]["command"] == "/usr/local/bin/emisar-mcp"
    assert config["mcpServers"]["emisar"]["env"]["XDG_CONFIG_HOME"] == "/config"

    assert render_click(lv, "select_client", %{"client" => "coop"}) =~ raw
    assert Repo.all(ApiKey) == [key]

    assert %ApiKey{id: key_id} = ApiKeys.peek_api_key_by_secret(raw)
    assert key_id == key.id
    assert has_element?(lv, "#agent-connection-status[data-state='connected']")

    render_click(lv, "select_client", %{"client" => "codex"})
    refute render(lv) =~ raw
  end

  test "co:op setup shows the complete procedure and filled configuration together", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/agents/connect")
    render_click(lv, "select_client", %{"client" => "coop"})

    assert has_element?(lv, "#coop-install-step", "Install co:op")

    init_commands =
      lv
      |> element("#coop-init")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert init_commands == "coop init\ncoop login codex"
    assert has_element?(lv, "#coop-container-step", "Prepare the container")
    assert has_element?(lv, "#coop-container-step", "~/.config/coop/coop.conf")

    storage_settings =
      lv
      |> element("#coop-storage")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert storage_settings ==
             "COOP_RUNTIME=docker\nCOOP_RUN_ARGS=-v coop-emisar-config:/config"

    assert has_element?(lv, "#coop-build", "coop build && coop doctor")
    assert has_element?(lv, "#coop-config-step", "Copy the MCP configuration")
    assert has_element?(lv, "#agent-connect-step", "4")
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

    documented_dockerfile =
      conn
      |> get(~p"/docs/connect-coop")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("pre")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
      |> Enum.find(&String.starts_with?(&1, "ARG COOP_BASE_IMAGE=coop-box"))

    assert dockerfile == documented_dockerfile
    assert dockerfile =~ "FROM ${COOP_BASE_IMAGE}"

    assert dockerfile =~ "curl -fsSL https://emisar.dev/install-mcp.sh | bash -s -- --yes"

    assert dockerfile =~ "install -d -m 700 -o node -g node /config"
  end

  test "a viewer cannot mint a co:op key through forged events", %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    viewer = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: viewer.id,
      role: "viewer"
    )

    {:ok, lv, _} = conn |> log_in_user(viewer) |> live(~p"/app/#{account}/agents/connect")

    assert render_click(lv, "select_client", %{"client" => "coop"}) =~
             "You don&#39;t have permission to do that."

    assert render_click(lv, "reveal_snippet", %{}) =~ "You don&#39;t have permission to do that."
    assert Repo.all(ApiKey) == []
    refute has_element?(lv, "#coop-config")
  end

  test "optional co:op tool-prompt guidance is collapsed and links to working docs", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/agents/connect")
    render_click(lv, "select_client", %{"client" => "coop"})

    assert has_element?(lv, "#agent-connect-step details#coop-tool-prompts summary", "optional")
    refute has_element?(lv, "#coop-tool-prompts[open]")
    assert has_element?(lv, "#coop-tool-prompts", "all tools inside the sandbox")
    [key] = Repo.all(ApiKey)

    for path <- ["/docs/connect-coop#tool-permissions", "/docs/policies-and-approvals"] do
      assert has_element?(lv, "#coop-tool-prompts a[href='#{path}']")
      uri = URI.parse(path)
      html = conn |> get(uri.path) |> html_response(200)

      if uri.fragment do
        assert html
               |> LazyHTML.from_document()
               |> LazyHTML.query("##{uri.fragment}")
               |> Enum.count() ==
                 1

        for agent <- ~w(CODEX CLAUDE GEMINI GROK) do
          assert html =~ "COOP_#{agent}_CMD"
        end
      end
    end

    render_click(lv, "select_client", %{"client" => "coop"})
    assert has_element?(lv, "#coop-tool-prompts")
    refute has_element?(lv, "#coop-tool-prompts[open]")
    assert Repo.all(ApiKey) == [key]

    render_click(lv, "select_client", %{"client" => "codex"})
    refute has_element?(lv, "#coop-tool-prompts")
  end

  test "an operator's automatic key stays in the current account despite forged scope", %{
    conn: conn
  } do
    account = Fixtures.Accounts.create_account()
    other_account = Fixtures.Accounts.create_account()
    operator = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    {:ok, lv, _} = conn |> log_in_user(operator) |> live(~p"/app/#{account}/agents/connect")

    render_click(lv, "select_client", %{"client" => "coop", "account_id" => other_account.id})

    assert has_element?(lv, "#coop-config")
    [key] = Repo.all(ApiKey)
    assert key.account_id == account.id
    assert key.created_by_membership_id == membership.id
  end

  test "failed configuration preparation stays inline and can be retried", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/agents/connect")
    downgraded = Fixtures.Memberships.force_role(membership, "viewer")

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
end
