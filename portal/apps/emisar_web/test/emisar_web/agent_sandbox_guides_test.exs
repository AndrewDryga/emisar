defmodule EmisarWeb.AgentSandboxGuidesTest do
  use EmisarWeb.ConnCase, async: true

  @path "/docs/connect-agent-sandboxes"
  @legacy_paths %{
    "/docs/connect-coop" => "#coop",
    "/docs/connect-docker-sandboxes" => "#docker-sandboxes",
    "/docs/connect-nono" => "#nono",
    "/docs/connect-dev-containers" => "#dev-containers"
  }

  test "one sandbox guide compares the supported coding agents and recommends co:op", %{
    conn: conn
  } do
    html = conn |> get(@path) |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query("h1") |> LazyHTML.text() |> String.trim() ==
             "Agent sandboxes"

    assert html =~ "We recommend"
    assert html =~ "free, open-source"

    rows =
      doc
      |> LazyHTML.query("h2#choose + div tbody tr")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

    assert rows == [
             "co:op Recommended Codex, Claude Code, Gemini CLI, Grok CLI You want to choose which local files and tools enter the sandbox.",
             "Docker Sandboxes Claude Code, Codex, Devin, Gemini CLI, Kiro, OpenCode You already use Docker's sandbox workflow.",
             "nono Any terminal agent with a suitable profile You prefer an operating-system profile.",
             "Dev Containers Any CLI agent installed in the container Your project already uses a Dev Container."
           ]

    assert html =~ "https://docs.docker.com/ai/sandboxes/mcp-gateway/"
    assert html =~ "https://registry.nono.sh"
  end

  test "the guide defers generated setup to the console and keeps one simple test", %{conn: conn} do
    html = conn |> get(@path) |> html_response(200)

    assert html =~ ~s(href="/app/agents/connect")
    assert html =~ ~s(href="/app/audit")
    assert html =~ "Follow the steps shown there."
    assert html =~ "Agent connected"
    refute html =~ "EMISAR_API_KEY"
    refute html =~ "install-mcp.sh"
    refute html =~ "Set up manually"
    refute html =~ "<pre"
  end

  test "each sandbox keeps its requirements, lifecycle quirk, and own limits", %{conn: conn} do
    html = conn |> get(@path) |> html_response(200)
    doc = LazyHTML.from_document(html)

    for id <- ~w(coop docker-sandboxes nono dev-containers) do
      assert doc |> LazyHTML.query("h2##{id}") |> Enum.count() == 1
      assert doc |> LazyHTML.query("h3##{id}-limits-and-risks") |> Enum.count() == 1
    end

    assert html =~ ".coopignore"
    assert html =~ ".gitignore"
    assert html =~ "Anything you mount or pass into the sandbox"
    assert html =~ "COOP_CODEX_CMD"
    assert html =~ "COOP_CLAUDE_CMD"
    assert html =~ "COOP_GEMINI_CMD"
    assert html =~ "COOP_GROK_CMD"

    assert html =~ "Docker shares the project directory"
    assert html =~ "temporary artifacts"
    assert html =~ "MCP launcher runs on the host"

    assert html =~ "including everything in its working directory"
    assert html =~ "Rotate the key manually"

    assert html =~ "credential-sharing settings"
    assert html =~ "never mount the host's Docker socket"
    assert html =~ "The default configuration does not restrict outbound network access"
    refute html =~ "runs Codex"
    refute html =~ "Codex profile"
    refute html =~ "private Codex configuration"
  end

  test "runtime evidence stays positive and concise", %{conn: conn} do
    html = conn |> get(@path) |> html_response(200)

    assert html =~
             "Tested with Docker Sandboxes 0.39.0, nono 0.75.0, and Dev Containers CLI 0.89.0 on macOS on September 7, 2026."

    refute html =~ "Last reviewed"
    refute html =~ "signed-in agent"
    refute html =~ "not part of that test"
    refute html =~ "live-tested"
  end

  test "legacy sandbox guide URLs redirect permanently to their sections", %{conn: conn} do
    for {path, fragment} <- @legacy_paths do
      response = conn |> recycle() |> get(path)

      assert redirected_to(response, :moved_permanently) == @path <> fragment
    end
  end

  test "the docs index and sitemap publish only the canonical guide", %{conn: conn} do
    for source <- ["/docs", "/sitemap.xml"] do
      body = conn |> recycle() |> get(source) |> response(200)

      assert body =~ @path
      for path <- Map.keys(@legacy_paths), do: refute(body =~ path)
    end
  end

  test "agent sandboxes is one page in the Connect navigation section" do
    sections =
      EmisarWeb.DocsNav.groups()
      |> Enum.find(&(&1.label == "AI agents"))
      |> Map.fetch!(:sections)

    connect = Enum.find(sections, &(&1.label == "Connect"))

    assert Enum.map(connect.pages, & &1.slug) == [
             "connect-cli-agent",
             "connect-claude-ai",
             "connect-chatgpt",
             "connect-agent-sandboxes"
           ]

    refute Enum.any?(sections, &(&1.label == "Agent sandboxes"))
  end

  test "installer prerequisites do not require optional GitHub CLI", %{conn: conn} do
    for path <- ~w(
      /docs/quickstart
      /docs/connect-cli-agent
      /docs/bridge-upgrades
      /docs/host-install
      /docs/runner-upgrades
      /docs/autoscaling-fleets
    ) do
      prerequisites =
        conn
        |> recycle()
        |> get(path)
        |> html_response(200)
        |> String.split("<h2", parts: 2)
        |> hd()

      refute prerequisites =~ "GitHub CLI"
      refute prerequisites =~ "gh attestation"
    end
  end
end
