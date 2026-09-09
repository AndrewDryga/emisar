defmodule EmisarWeb.AgentSandboxGuidesTest do
  use EmisarWeb.ConnCase, async: true

  @guides [
    %{
      path: "/docs/connect-docker-sandboxes",
      title: "Docker Sandboxes",
      evidence: "Docker Sandboxes 0.39.0",
      commands: ["sbx mcp add emisar", "--static-mcp emisar", "sbx mcp rm emisar"],
      boundary: ["runs on the host", "does not need the raw key"]
    },
    %{
      path: "/docs/connect-nono",
      title: "nono",
      evidence: "nono 0.75.0",
      commands: ["nono search codex", "--allow-domain emisar.dev"],
      boundary: ["automatic key rotation was disabled", "Treat rotation as manual"]
    },
    %{
      path: "/docs/connect-dev-containers",
      title: "Dev Containers",
      evidence: "Dev Containers CLI 0.89.0",
      commands: ["--cap-drop=ALL", "XDG_CONFIG_HOME = \"/config\""],
      boundary: ["does not restrict outbound networking", "does not hide secrets"]
    }
  ]

  test "the three sandbox guides are public, complete, and qualification-bounded", %{conn: conn} do
    for guide <- @guides do
      html = conn |> recycle() |> get(guide.path) |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert doc |> LazyHTML.query("h1") |> LazyHTML.text() |> String.trim() == guide.title
      assert html =~ guide.evidence
      assert html =~ "signed-in agent"
      assert html =~ "not part of that test"
      assert html =~ ~s(href="/app/agents/connect")
      assert html =~ ~s(href="/app/audit")
      assert html =~ ~s(href="/docs/policies-and-approvals")
      assert html =~ "linux.uptime"

      for command <- guide.commands, do: assert(html =~ command)
      for claim <- guide.boundary, do: assert(html =~ claim)
    end
  end

  test "the docs index and sitemap discover every sandbox guide", %{conn: conn} do
    for source <- ["/docs", "/sitemap.xml"] do
      body = conn |> recycle() |> get(source) |> response(200)

      for guide <- @guides do
        assert body =~ guide.path
      end
    end
  end

  test "agent sandboxes are a dedicated navigation section led by co:op" do
    section =
      EmisarWeb.DocsNav.groups()
      |> Enum.find(&(&1.label == "AI agents"))
      |> Map.fetch!(:sections)
      |> Enum.find(&(&1.label == "Agent sandboxes"))

    assert Enum.map(section.pages, & &1.slug) == [
             "connect-coop",
             "connect-docker-sandboxes",
             "connect-nono",
             "connect-dev-containers"
           ]
  end
end
