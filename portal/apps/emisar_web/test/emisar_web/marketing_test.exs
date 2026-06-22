defmodule EmisarWeb.MarketingTest do
  use EmisarWeb.ConnCase, async: true

  @routes ~w(
    /
    /ai
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
    /docs/sso
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

  test "shared CTA button + heading scale render on representative pages", %{conn: conn} do
    # Hero: the home title uses the larger :display scale; a docs page uses
    # the standard :hero scale. Both are a single <h1> with the documented
    # size class — the scale standardizes sizing without touching the tag.
    # marketing_heading leads every title with text-balance (the micro-craft
    # pass), so the class begins "text-balance font-bold …" then the scale.
    # (Home appends page-specific responsive overrides after the scale, so
    # match the class prefix, not a closed attribute — like the docs line.)
    home = conn |> get(~p"/") |> html_response(200)

    assert home =~
             ~s(<h1 class="text-balance font-bold tracking-tight text-zinc-50 text-6xl md:text-7xl)

    docs = conn |> get(~p"/docs/quickstart") |> html_response(200)

    assert docs =~
             ~s(<h1 class="text-balance font-bold tracking-tight text-zinc-50 text-4xl md:text-5xl)

    # The pricing tier buttons route through the one marketing-CTA component:
    # full-width pills, primary (Team) and secondary (Free/Enterprise).
    pricing = conn |> get(~p"/pricing") |> html_response(200)
    assert pricing =~ "bg-brand-500 text-zinc-950 hover:bg-brand-400"
    assert pricing =~ "ring-1 ring-zinc-800 hover:ring-zinc-700"

    # The outbound CTA (Open an issue) keeps its safe-rel pair after routing
    # through the component's external branch.
    docs_index = conn |> get(~p"/docs") |> html_response(200)
    assert docs_index =~ ~s(rel="noopener noreferrer")
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

  test "the /ai landing page leads with the blind-AI pain and converts", %{conn: conn} do
    html = conn |> get(~p"/ai") |> html_response(200)

    # Differentiated from home: lead with the relatable "your AI is blind" pain,
    # then the practical three-step setup.
    assert html =~ "brilliant"
    assert html =~ "blind"
    assert html =~ "Install the runner"
    assert html =~ "Connect your LLM"
    assert html =~ "Ask in plain English"

    # The capabilities (the magic) and a brief safety reassurance. The deep
    # security model + the live incident demo live on home/security — /ai
    # points there instead of duplicating them.
    assert html =~ "Read &amp; tail logs"
    assert html =~ "gated catalog"
    assert html =~ "No SSH, no standing access"
    refute html =~ "data-emisar-demo"
    assert html =~ ~s(href="/security")

    # A convinced reader gets the Start-free conversion CTA.
    assert html =~ "Start free"
    assert html =~ ~s(href="/sign_up")

    # FAQ accordion + its FAQPage rich data are driven by the same list.
    assert html =~ "Is it safe to let an AI touch production?"
    assert html =~ ~s("@type":"FAQPage")

    # phx-no-format is a formatter directive — it must not reach the markup.
    refute html =~ "phx-no-format"
  end

  test "the sitemap lists the /ai landing page", %{conn: conn} do
    body = conn |> get(~p"/sitemap.xml") |> response(200)
    assert body =~ "https://emisar.dev/ai</loc>"
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

  test "quickstart documents the optional auto-permit step, framed as safe server-side gating",
       %{conn: conn} do
    html = conn |> get(~p"/docs/quickstart") |> html_response(200)

    # The optional subsection + the WHY (safe BECAUSE emisar gates server-side).
    assert html =~ "Optional: stop the per-tool prompts"
    assert html =~ "server-side"
    assert html =~ "never bypasses emisar"
    # The verified Claude Code rule, server-rendered for the SEO surface.
    assert html =~ "mcp__emisar__*"
  end

  test "docs states the supported deployment boundary", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "supported product is the hosted emisar control plane today"
    refute html =~ "Run the control plane in your own VPC"
  end

  test "SSO docs page covers login, SCIM deprovisioning, and the subject-not-email binding",
       %{conn: conn} do
    html = conn |> get(~p"/docs/sso") |> html_response(200)

    # The two halves of the feature.
    assert html =~ "Single sign-on"
    assert html =~ "directory sync"
    # The registered callback + SCIM base URL the operator must wire up.
    assert html =~ "/sign_in/sso/callback"
    assert html =~ "/scim/v2"
    # The headline value + the honest security posture (must match the built behavior).
    assert html =~ "issuer + subject, not email"
    assert html =~ "suspends"
    refute html =~ "deletes the user"
    # Owner is never assignable via sync.
    assert html =~ "Owner is never assignable through"
  end

  test "the sitemap lists the SSO docs page", %{conn: conn} do
    body = conn |> get(~p"/sitemap.xml") |> response(200)
    assert body =~ "https://emisar.dev/docs/sso</loc>"
  end

  test "marketing pages include a large social preview image", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(property="og:image")
    assert html =~ "/images/og/emisar-og.webp"
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
    # the Claude tool call, the source-verification beat, and the approval beat.
    assert html =~ ">curl -sSL https://emisar.dev/install.sh | sudo bash</div>"
    assert html =~ "emisar · nomad.alloc_stop(alloc:"
    assert html =~ "read NodeStageVolume in src/driver/index.js"
    assert html =~ "⏸ pending approval — nomad.alloc_stop is high-risk"
    assert html =~ "✓ approved by you · one use · audit event recorded"

    # The PR diff block is server-rendered too — the driver-config why-comment
    # plus the diff context, with intentional indentation preserved verbatim (no
    # template-indent leak, no whitespace collapse).
    assert html =~ "kept for when upstream honors it"
    assert html =~ ">  node:</div>"

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
      # indicator is the rounded brand underline span we added.
      html = conn |> get(~p"/pricing") |> html_response(200)
      assert html =~ "bg-brand-400"
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
