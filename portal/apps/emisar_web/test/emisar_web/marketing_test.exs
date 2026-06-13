defmodule EmisarWeb.MarketingTest do
  use EmisarWeb.ConnCase, async: true

  @routes ~w(
    /
    /pricing
    /security
    /docs
    /docs/quickstart
    /docs/action-packs
    /docs/security-model
    /docs/connect-an-llm
    /docs/publishing-packs
    /docs/policies-and-approvals
    /docs/runbooks
    /docs/teams-and-access
    /docs/runners
    /docs/audit-and-siem
    /changelog
    /about
    /privacy
    /terms
    /refund-policy
    /packs
    /packs/postgres
    /packs/cassandra
    /use-cases/cassandra-ops
    /use-cases/postgres-ops
    /use-cases/csi-data-loss
    /compare/raw-ssh-for-ai
    /compare/custom-mcp-server
    /zero-trust
  )

  for route <- @routes do
    test "GET #{route} renders 200", %{conn: conn} do
      conn = get(conn, unquote(route))
      assert html_response(conn, 200)
    end
  end

  test "deep pages a convinced reader lands on carry a Start-free conversion CTA",
       %{conn: conn} do
    for route <- ~w(
          /use-cases/cassandra-ops
          /use-cases/postgres-ops
          /compare/raw-ssh-for-ai
          /compare/custom-mcp-server
          /docs/connect-an-llm
          /security
        ) do
      html = conn |> get(route) |> html_response(200)
      assert html =~ "Start free", "no Start-free CTA on #{route}"
      assert html =~ ~s(href="/sign_up"), "no sign-up link on #{route}"
    end
  end

  test "landing page mentions the positioning", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "emisar"
    assert html =~ "Sign in"
    assert html =~ "Start free"
    assert html =~ "pack trust"
    assert html =~ "source-available"
    refute html =~ "signed audit log"
    # A signed-out visitor gets the auth CTAs, not a dashboard link.
    refute html =~ ~s(href="/app")
  end

  test "marketing nav swaps to a Dashboard link when the visitor is signed in",
       %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Dashboard"
    assert html =~ ~s(href="/app")
  end

  test "pricing page mentions the three tiers", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)
    assert html =~ "Free"
    assert html =~ "Team"
    assert html =~ "Enterprise"
    assert html =~ "365-day audit retention"
    refute html =~ "99.9% uptime SLA"
    refute html =~ "On-prem / self-hosted option"
  end

  test "pricing page emits a FAQPage with the visible questions in sync", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)

    # The visible accordion and the FAQPage JSON-LD are driven by the same
    # list, so a question that renders must also appear in the structured data.
    assert html =~ "What counts as a"
    assert html =~ ~s("@type":"FAQPage")
    assert html =~ "How does billing work?"
  end

  test "docs states the supported deployment boundary", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "supported product is the hosted emisar control plane today"
    refute html =~ "Run the control plane in your own VPC"
  end

  test "marketing pages include a large social preview image", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(property="og:image")
    assert html =~ "/images/og/emisar-product.webp"
    assert html =~ ~s(name="twitter:card" content="summary_large_image")
    assert html =~ ~s("FAQPage")
    refute html =~ "Phoenix.HTML.raw"
  end

  test "landing page renders the interactive demo verbatim for no-JS + crawlers", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # The component + the hooks emisar_demo.js enhances.
    assert html =~ "data-emisar-demo"
    assert html =~ ~s(data-demo-tab="server")
    assert html =~ ~s(data-demo-tab="llm")
    assert html =~ "data-demo-replay"

    # The whole incident is server-rendered for no-JS + crawlers — install,
    # the Claude tool call, and the approval beat.
    assert html =~ ">curl -sSL https://emisar.dev/install.sh | sudo bash</div>"
    assert html =~ "emisar · nomad.alloc_stop(alloc:"
    assert html =~ "⏸ pending approval — nomad.alloc_stop is high-risk"
    assert html =~ "✓ approved by you · one use · audit event recorded"

    # The PR diff block is server-rendered too — its why-comment plus the
    # HCL config, with intentional indentation preserved verbatim (no
    # template-indent leak, no whitespace collapse).
    assert html =~ "blkid-empty → the driver auto-mkfs"
    assert html =~ ">  node {</div>"

    # phx-no-format is a mix-format directive only — it must not survive into
    # the served markup.
    refute html =~ "phx-no-format"
  end

  test "zero-trust page cites the framework honestly without claiming endorsement", %{conn: conn} do
    html = conn |> get(~p"/zero-trust") |> html_response(200)

    # Cites the source framework and links it.
    assert html =~ "Zero Trust for AI Agents"
    assert html =~ "Claude-eBook-Zero-Trust-for-AI-Agents"

    # Maps a concrete control to an emisar feature.
    assert html =~ "Least agency"
    assert html =~ "Human-in-the-loop approval"

    # Stays honest: the not-affiliated disclaimer and the explicit scope
    # boundary must both be present — this is a security product, so the
    # framing is "we implement it", never "they endorse us".
    assert html =~ "not affiliated with, endorsed by, or sponsored by Anthropic"
    assert html =~ "One pillar, not the whole framework"
  end

  test "landing page surfaces the Zero Trust framework with the not-affiliated note", %{
    conn: conn
  } do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Zero Trust for AI Agents"
    assert html =~ "Not affiliated with or endorsed by Anthropic"
    assert html =~ ~p"/zero-trust"
  end

  test "healthz returns 200 when the DB is reachable", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  describe "marketing nav" do
    test "ships a hamburger button + drawer for mobile viewports", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # Desktop nav is hidden on mobile (md:flex), so the drawer is
      # the only way to reach the secondary links on a phone — make
      # sure both the trigger and the drawer container are present.
      assert html =~ ~s(id="marketing-mobile-nav")
      assert html =~ "aria-label=\"Open menu\""
      assert html =~ "aria-label=\"Close menu\""
    end

    test "renders the active-page indicator on the current section", %{conn: conn} do
      # Pricing route should mark its own nav link active. The
      # indicator is the rounded indigo underline span we added.
      html = conn |> get(~p"/pricing") |> html_response(200)
      assert html =~ "bg-indigo-400"
    end
  end

  describe "structured data" do
    test "a docs page emits BreadcrumbList JSON-LD (Home → Docs → page)", %{conn: conn} do
      html = conn |> get(~p"/docs/runners") |> html_response(200)
      assert html =~ ~s(type="application/ld+json")
      assert html =~ "BreadcrumbList"
      assert html =~ ~s("name":"Home")
      assert html =~ ~s("name":"Docs")
    end

    test "a non-docs generated page emits a 2-level breadcrumb (no Docs crumb)", %{conn: conn} do
      html = conn |> get(~p"/compare/raw-ssh-for-ai") |> html_response(200)
      assert html =~ "BreadcrumbList"
      assert html =~ ~s("name":"Home")
      refute html =~ ~s("name":"Docs")
    end
  end
end
