defmodule EmisarWeb.AgentSandboxGuidesTest do
  use EmisarWeb.ConnCase, async: true

  @guides [
    %{
      path: "/docs/connect-docker-sandboxes",
      title: "Docker Sandboxes",
      evidence: "Docker Sandboxes 0.39.0",
      boundary: ["runs on the host", "network policy"]
    },
    %{
      path: "/docs/connect-nono",
      title: "nono",
      evidence: "nono 0.75.0",
      boundary: ["Automatic key rotation is unavailable", "profile you run"]
    },
    %{
      path: "/docs/connect-dev-containers",
      title: "Dev Containers",
      evidence: "Dev Containers CLI 0.89.0",
      boundary: ["Dropping Linux capabilities", "does not restrict outbound"]
    }
  ]

  test "the sandbox docs defer generated setup to the console and retain qualification boundaries",
       %{
         conn: conn
       } do
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
      assert html =~ "Follow the numbered steps shown there"
      assert html =~ "generates the key, configuration, and"
      assert html =~ "Agent connected"
      refute html =~ "GitHub CLI"
      refute html =~ "/tmp/install-mcp.sh"
      refute html =~ "install-mcp.sh"
      refute html =~ "EMISAR_API_KEY"
      refute html =~ "Set up manually"
      refute html =~ "linux.uptime"
      refute html =~ "<pre"

      heading =
        doc
        |> LazyHTML.query("h2#limits-and-risks")
        |> LazyHTML.text()
        |> String.trim()
        |> String.trim_trailing("#")
        |> String.trim()

      assert heading == "Limits & risks"

      for claim <- guide.boundary, do: assert(html =~ claim)
    end
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
