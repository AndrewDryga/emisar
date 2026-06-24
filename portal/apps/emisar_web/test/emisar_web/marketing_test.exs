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
    /docs/signed-dispatch
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
    /use-cases
    /use-cases/csi-data-loss
    /use-cases/ingress-502
    /compare/raw-ssh-for-ai
    /compare/custom-mcp-server
    /zero-trust
    /how-it-works
    /trust
    /dpa
    /docs/mcp-reference
    /guides
    /guides/give-ai-agents-safe-production-access
  )

  for route <- @routes do
    test "GET #{route} renders 200", %{conn: conn} do
      conn = get(conn, unquote(route))
      assert html_response(conn, 200)
    end
  end

  describe "indexable + CSP on every server-rendered marketing page" do
    # @routes is the full public marketing surface; every one is server-
    # rendered through the :browser pipeline and deliberately skips the
    # :noindex pipeline (router.ex), so each must (a) carry the strict CSP
    # header with a nonce on script-src and (b) stay indexable — the exact
    # opposite of the 404/ErrorHTML page, which DOES emit a robots noindex.
    # One loop closes the "Security: Indexable + CSP" row on MKT-001…025
    # and the legal pages MKT-034…036.
    #
    for route <- @routes do
      test "GET #{route} carries the CSP header with a script-src nonce", %{conn: conn} do
        conn = get(conn, unquote(route))
        [csp] = get_resp_header(conn, "content-security-policy")

        # The nonce stamped on script-src is what lets the JSON-LD <script>
        # run under script-src 'self' without 'unsafe-inline'. Scope the
        # 'unsafe-inline' refute to the script-src directive — style-src
        # intentionally allows inline styles, which mustn't fail this.
        assert [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)
        assert csp =~ "script-src 'self' 'nonce-#{nonce}'"
        [_, script_src] = Regex.run(~r/script-src ([^;]+)/, csp)
        refute script_src =~ "'unsafe-inline'"
      end

      test "GET #{route} stays indexable (no robots noindex)", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)

        # Marketing/docs pages must rank: the conn-level :noindex assign is
        # never set on these routes, so the robots meta must be absent. The
        # 404 page is the deliberate inverse and DOES carry it.
        refute html =~ ~s(name="robots")
      end
    end
  end

  test "deep pages a convinced reader lands on carry a Start-free conversion CTA",
       %{conn: conn} do
    for route <- ~w(
          /use-cases/ingress-502
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
    # marketing_heading leads every title with text-balance + the signature
    # font-display treatment, so the class begins "text-balance font-display
    # font-bold …" then the scale (which now carries the tighter tracking).
    # (Home appends page-specific responsive overrides after the scale, so
    # match the class prefix, not a closed attribute — like the docs line.)
    home = conn |> get(~p"/") |> html_response(200)

    assert home =~
             ~s(<h1 class="text-balance font-display font-bold text-zinc-50 text-4xl tracking-[-0.035em] sm:text-6xl md:text-7xl)

    docs = conn |> get(~p"/docs/quickstart") |> html_response(200)

    assert docs =~
             ~s(<h1 class="text-balance font-display font-bold text-zinc-50 text-4xl tracking-[-0.03em] md:text-5xl)

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

  test "the use-cases hub lists the case studies, links each, and carries an ItemList",
       %{conn: conn} do
    html = conn |> get(~p"/use-cases") |> html_response(200)

    # Everyday daily-driver scenarios + the deep incident war stories.
    assert html =~ "saves the night"
    assert html =~ "Pre-migration go"
    assert html =~ "The work that never makes a post-mortem"
    # The two real incidents are featured and linked from the hub. The weaker
    # "real-shape" datastore walkthroughs were cut from the war stories; they
    # live on as pack-supporting pages, reachable from their packs and docs.
    assert html =~ "The 33-hour wipe"
    assert html =~ "The fleet-wide 502 that no backend was causing"
    assert html =~ ~s(href="/use-cases/csi-data-loss")
    assert html =~ ~s(href="/use-cases/ingress-502")
    # Structured data so the case studies can surface as a list.
    assert html =~ ~s("@type":"ItemList")
    assert html =~ "BreadcrumbList"
    # Converts via the shared CTA.
    assert html =~ "Start free"
  end

  test "the sitemap lists the use-cases hub", %{conn: conn} do
    body = conn |> get(~p"/sitemap.xml") |> response(200)
    assert body =~ "https://emisar.dev/use-cases</loc>"
  end

  test "marketing pages tag the body so the marketing-scoped inline-code CSS applies",
       %{conn: conn} do
    # The `:where(.marketing) code` rule in app.css hangs off this body class.
    # Controller-rendered marketing/docs pages carry it; the LiveView console
    # (app_js?) does not, so the calm console keeps its own neutral code styling.
    html = conn |> get(~p"/use-cases/ingress-502") |> html_response(200)
    assert html =~ ~r/<body[^>]*\bmarketing\b/
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

  test "healthz carries cache-control: no-store so a 200 is never cached", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "healthz is reachable with no session/auth/CSRF", %{conn: conn} do
    # The route rides the bare :api pipeline (no fetch_session / fetch_current_user
    # / protect_from_forgery), so a probe with no cookies still answers 200 — Fly's
    # health checker carries no session.
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
    refute conn.assigns[:current_user]
    assert conn.req_cookies == %{}
  end

  test "healthz only answers GET — POST hits no route and parses no input", %{conn: conn} do
    # The route is `get "/healthz"` only, so a POST matches nothing and falls to
    # the not-found path (404) — the probe handler never runs, no body is parsed.
    conn = post(conn, "/healthz")
    assert conn.status == 404
  end

  describe "marketing nav" do
    test "ships a hamburger button + drawer for mobile viewports", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # Desktop nav is hidden below lg (lg:flex), so the drawer is
      # the only way to reach the secondary links on a phone/tablet —
      # make sure both the trigger and the drawer container are present.
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

    test "the packs index emits ItemList + BreadcrumbList JSON-LD", %{conn: conn} do
      html = conn |> get(~p"/packs") |> html_response(200)
      assert html =~ ~s(type="application/ld+json")
      assert html =~ ~s("@type":"ItemList")
      assert html =~ "BreadcrumbList"
      # Every published pack is a crawlable ListItem pointing at its detail page.
      # (JSON-LD is html_safe-escaped, so the slashes are \/ in the markup.)
      assert html =~ ~s("@type":"ListItem")
      assert html =~ "packs\\/postgres"
      # The client-side search's markup contract (the filter is a no-op without
      # JS; the full list stays server-rendered for crawlers).
      assert html =~ ~s(id="pack-search")
      assert html =~ "data-pack-name"
      assert html =~ "data-pack-section"
      # The one-command install story is on the page, not buried in docs.
      assert html =~ "sudo emisar pack install postgres"
    end

    test "a pack detail page emits SoftwareApplication + a 3-level breadcrumb", %{conn: conn} do
      html = conn |> get(~p"/packs/postgres") |> html_response(200)
      assert html =~ ~s("@type":"SoftwareApplication")
      assert html =~ ~s("applicationCategory":"DeveloperApplication")
      assert html =~ ~s("softwareVersion")
      assert html =~ "BreadcrumbList"
      assert html =~ ~s("name":"Action packs")
    end
  end

  describe "outbound link safety" do
    test "the /security page links the disclosure mailbox and tab-safe external links",
         %{conn: conn} do
      html = conn |> get(~p"/security") |> html_response(200)

      # The responsible-disclosure mailbox the SECURITY.md + site advertise.
      assert html =~ ~s(mailto:security@emisar.dev)

      # Every external link (the Anthropic Zero-Trust PDF, SECURITY.md on
      # GitHub) opens in a new tab AND carries the safe-rel pair — a
      # `target="_blank"` without `rel="noopener"` is a reverse-tabnabbing hole.
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")

      for link <- external_links(html) do
        assert link =~ ~s(rel="noopener noreferrer"),
               "external link missing safe rel on /security: #{link}"
      end
    end

    test "the /zero-trust page's external framework PDF carries the safe-rel pair", %{conn: conn} do
      html = conn |> get(~p"/zero-trust") |> html_response(200)

      assert html =~ ~s(target="_blank")

      for link <- external_links(html) do
        assert link =~ ~s(rel="noopener noreferrer"),
               "external link missing safe rel on /zero-trust: #{link}"
      end
    end

    # The pages whose copy carries an off-site link (changelog's RSS/repo,
    # about's GitHub/personal site, the publishing-packs repo tree, the CSI
    # case study's upstream kubernetes#95183 issue): every external anchor
    # must open in a new tab AND carry rel="noopener noreferrer", or a
    # `target="_blank"` is a reverse-tabnabbing hole.
    #
    for route <- ~w(/changelog /about /docs/publishing-packs /use-cases/csi-data-loss) do
      test "GET #{route} external links carry the safe-rel pair", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)
        links = external_links(html)

        assert links != [], "expected at least one external link on #{unquote(route)}"

        for link <- links do
          assert link =~ ~s(rel="noopener noreferrer"),
                 "external link missing safe rel on #{unquote(route)}: #{link}"
        end
      end
    end
  end

  describe "docs hub" do
    test "every doc-card target on the docs index resolves to a 200 page", %{conn: conn} do
      index = conn |> get(~p"/docs") |> html_response(200)

      # The hub is the crawl entry point for the whole docs tree — every
      # card it links must resolve, or a reader (and a crawler) hits a
      # dead end. Pull the on-page hrefs and GET each: the index links all
      # eleven doc sub-pages plus /pricing.
      for path <- ~w(
            /docs/quickstart
            /docs/connect-an-llm
            /docs/policies-and-approvals
            /docs/runbooks
            /docs/teams-and-access
            /docs/sso
            /docs/runners
            /docs/audit-and-siem
            /docs/action-packs
            /docs/publishing-packs
            /docs/security-model
            /docs/signed-dispatch
            /pricing
          ) do
        assert index =~ ~s(href="#{path}"), "docs index doesn't link #{path}"
        assert conn |> get(path) |> html_response(200), "docs card target #{path} is not 200"
      end
    end

    test "the docs hub offers a support mailbox", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)
      assert html =~ ~s(mailto:support@emisar.dev)
    end
  end

  describe "per-page content sections" do
    # Each marketing page renders its own documented sections. These assert
    # the STABLE, apostrophe-free headings/copy that the page actually
    # renders (read off the templates), so a section silently disappearing
    # surfaces — without pinning brittle full sentences a copy tweak would
    # break.

    test "the security page renders the trust-boundary diagram, key claims, and disclosures",
         %{conn: conn} do
      html = conn |> get(~p"/security") |> html_response(200)

      # The trust-boundary diagram: the gate between the untrusted client
      # and the host, with the pending → approved state chips.
      assert html =~ "trust boundary"
      assert html =~ "The gate · control plane"
      assert html =~ "require approval"
      assert html =~ "approved"

      # The concrete claims a security reviewer scans for.
      assert html =~ "20+ built-in patterns"
      assert html =~ "RFC 6238"
      assert html =~ "read-only audit key"

      # The honest not-affiliated note (this is a security product; the
      # framing is "we implement it", never "they endorse us").
      assert html =~ "Not affiliated with or endorsed by Anthropic"
    end

    test "the zero-trust page maps concrete controls and stays honest about scope",
         %{conn: conn} do
      html = conn |> get(~p"/zero-trust") |> html_response(200)

      # The 10-control mapping table — assert two concrete rows render.
      assert html =~ "Least agency"
      assert html =~ "Human-in-the-loop approval for high-risk actions"

      # The three framework tiers the mapping is grouped under.
      assert html =~ "Foundation"
      assert html =~ "Enterprise"
      assert html =~ "Advanced"

      # The honesty rails (also covered by the copy test above, asserted
      # here as part of the page's required sections).
      assert html =~ "One pillar, not the whole framework"
    end

    test "the zero-trust page carries its CTAs and the framework PDF link", %{conn: conn} do
      html = conn |> get(~p"/zero-trust") |> html_response(200)

      # The conversion + deep-dive cross-links a convinced reader follows.
      assert html =~ ~s(href="/sign_up")
      assert html =~ ~s(href="/security")
      assert html =~ ~s(href="/docs/security-model")
      assert html =~ ~s(href="/use-cases/csi-data-loss")
      # The source framework PDF (the page's whole premise).
      assert html =~ "Claude-eBook-Zero-Trust-for-AI-Agents"
    end

    test "the connect-an-llm page renders every client config block", %{conn: conn} do
      html = conn |> get(~p"/docs/connect-an-llm") |> html_response(200)

      # The stdio-bridge config for each supported desktop/CLI client.
      assert html =~ "claude_desktop_config.json"
      assert html =~ ".cursor/mcp.json"
      assert html =~ "claude mcp add emisar"
      assert html =~ ".gemini/settings.json"
      assert html =~ "mcp_servers.emisar"
    end

    test "the changelog renders its entries and the feed links", %{conn: conn} do
      html = conn |> get(~p"/changelog") |> html_response(200)

      # The data-driven release entries (EmisarWeb.Changelog) — assert labels.
      assert html =~ "Runner 0.7"
      assert html =~ "Public beta control plane"
      assert html =~ "SSO and SCIM directory sync"
      assert html =~ "The foundation"
      assert html =~ "portal-v0.9.0"
      assert html =~ "runner-v0.7.4"

      # The first-party RSS feed, the repo, and the "see all" out-link.
      assert html =~ "/changelog.xml"
      assert html =~ "https://github.com/andrewdryga/emisar/releases"
      assert html =~ "See all releases on GitHub"
    end

    test "the about page renders its values, founder note, and CTAs", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      # Why-this-exists + the three value cards.
      assert html =~ "Why this exists"
      assert html =~ "Least privilege, always"
      assert html =~ "Auditability is non-negotiable"
      assert html =~ "Boring is a feature"

      # The founder note + its attribution.
      assert html =~ "A note from the founder"
      assert html =~ "founder"

      # The page's CTAs and source link.
      assert html =~ ~s(href="/sign_up")
      assert html =~ ~s(href="/docs")
      assert html =~ "https://github.com/andrewdryga/emisar"
    end

    test "the connect-an-llm page renders the verbatim endpoint references", %{conn: conn} do
      html = conn |> get(~p"/docs/connect-an-llm") |> html_response(200)

      # The remote MCP endpoint + the bridge install command + the REST
      # routes an operator copies verbatim. (The install URL is wrapped in a
      # syntax-highlight span, so assert the URL and the `| sudo bash` tail
      # as separate stable pieces rather than one contiguous literal.)
      assert html =~ "https://emisar.dev/api/mcp/rpc"
      assert html =~ "curl -sSL"
      assert html =~ "https://emisar.dev/install-mcp.sh"
      assert html =~ "| sudo bash"
      assert html =~ "GET /api/mcp/runners"
      assert html =~ "POST /api/mcp/tools/:action_id"
    end

    test "the quickstart renders the install command pinned to the TLS endpoint", %{conn: conn} do
      html = conn |> get(~p"/docs/quickstart") |> html_response(200)

      # The one-command install — the URL must be the literal TLS endpoint
      # (the same one /install.sh serves), and "read it first" links it.
      # The command wraps across a `\`-newline with the enrollment key
      # interpolated, so assert the stable contiguous pieces, not the whole
      # line as one string.
      assert html =~ "curl -sSL https://emisar.dev/install.sh"
      assert html =~ "sudo EMISAR_AUTH_KEY="
      assert html =~ "EMISAR_URL=https://emisar.dev bash"
      assert html =~ ~s(href="/install.sh")
    end

    test "the action-packs reference renders the YAML sections and registry links",
         %{conn: conn} do
      html = conn |> get(~p"/docs/action-packs") |> html_response(200)

      # The schema reference sections.
      assert html =~ "pack.yaml"
      assert html =~ "Field reference"
      assert html =~ "Pack trust"
      assert html =~ "Drift detection"

      # The registry + authoring cross-links.
      assert html =~ ~s(href="/packs")
      assert html =~ ~s(href="/docs/publishing-packs")
    end

    test "the security-model page renders the control mechanisms", %{conn: conn} do
      html = conn |> get(~p"/docs/security-model") |> html_response(200)

      # The risk tiers + the three policy decisions.
      assert html =~ "require_approval"
      assert html =~ "deny"
      assert html =~ "allow"
      assert html =~ "critical"

      # The runner journal path + its verify command.
      assert html =~ "/var/log/emisar/events.jsonl"
      assert html =~ "emisar audit verify"

      # The honest "what emisar is not" boundary section.
      assert html =~ "What emisar is not"
    end

    # The signed-dispatch operator guide: setup + the fleet key lifecycle
    # (distribute, rotate, revoke) plus the config tokens and a refusal code
    # an operator copies. Stable, apostrophe-free anchors per the describe note.
    test "the signed-dispatch page renders setup, fleet distribution, rotation, and revocation",
         %{conn: conn} do
      html = conn |> get(~p"/docs/signed-dispatch") |> html_response(200)

      # The section spine of the how-to.
      assert html =~ "Distributing keys across a fleet"
      assert html =~ "Rotating keys"
      assert html =~ "Revoking a key"

      # The exact knobs an operator sets on both ends.
      assert html =~ "emisar keygen"
      assert html =~ "enforce_signatures"
      assert html =~ "trusted_keys"
      assert html =~ "EMISAR_SIGNING_KEY"
      assert html =~ "max_attestation_age"

      # A refusal code from the troubleshooting table.
      assert html =~ "unknown_key"
    end

    test "the publishing-packs guide renders the operator commands", %{conn: conn} do
      html = conn |> get(~p"/docs/publishing-packs") |> html_response(200)

      assert html =~ "emisar pack validate"
      assert html =~ "emisar pack install"
      assert html =~ "systemctl reload emisar"
      assert html =~ "--hash"
    end

    test "the policies-and-approvals page renders the approval TTL and standing grants",
         %{conn: conn} do
      html = conn |> get(~p"/docs/policies-and-approvals") |> html_response(200)

      # The decision-making + approvals (24h TTL) + standing-grants sections.
      assert html =~ "require_approval"
      assert html =~ "24 hours"
      assert html =~ "Standing grants"
    end

    test "the runbooks page names the LLM tools it exposes", %{conn: conn} do
      html = conn |> get(~p"/docs/runbooks") |> html_response(200)
      assert html =~ "list_runbooks"
      assert html =~ "get_runbook"
    end

    test "the teams-and-access page renders all four roles", %{conn: conn} do
      html = conn |> get(~p"/docs/teams-and-access") |> html_response(200)
      assert html =~ "Owner"
      assert html =~ "Admin"
      assert html =~ "Operator"
      assert html =~ "Viewer"
      # The scoped-key shape an LLM-access reviewer checks.
      assert html =~ "audit:read"
    end

    test "the runners page renders the host CLI and uninstall flags", %{conn: conn} do
      html = conn |> get(~p"/docs/runners") |> html_response(200)

      # The host-side toolbox + clean removal + the TLS install endpoint.
      assert html =~ "emisar audit verify --all"
      assert html =~ "--uninstall"
      assert html =~ "--purge"
      assert html =~ "https://emisar.dev/install.sh"
    end

    test "the audit-and-siem page renders the SIEM curl and journal verify", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200)

      # The SIEM stream contract — endpoint, params, bearer auth, cursor.
      assert html =~ "https://emisar.dev/api/audit"
      assert html =~ "since="
      assert html =~ "limit="
      assert html =~ "Authorization: Bearer"
      assert html =~ "X-Next-Cursor"

      # The retention windows + the journal verify path.
      assert html =~ "/var/log/emisar/events.jsonl"
      assert html =~ "emisar audit verify --all"
    end

    test "the CSI data-loss use case renders its incident narrative and CTAs", %{conn: conn} do
      html = conn |> get(~p"/use-cases/csi-data-loss") |> html_response(200)

      assert html =~ "Case study · Storage"
      assert html =~ "Stop the bleed"
      assert html =~ ~s(href="/sign_up")
      assert html =~ ~s(href="/docs/security-model")
      assert html =~ ~s(href="/docs/action-packs")
    end

    test "the ingress-502 use case renders its incident narrative, the gated stop, and CTAs",
         %{conn: conn} do
      html = conn |> get(~p"/use-cases/ingress-502") |> html_response(200)

      assert html =~ "Case study · Ingress"
      assert html =~ "Stopping the bleed"
      # The honest beat: emisar didn't PREVENT the outage (no out-of-band step).
      assert html =~ "What emisar didn't do"
      # Two gated mutations actually executed (restart Consul, then resize Traefik) —
      # pending → approved, the product's whole thesis. The anycast drain wasn't needed
      # once Consul rejoined, but frr.bgp_neighbor_shutdown is still cited as the lever.
      assert html =~ "pending approval — linux.systemctl_restart is risk:high"
      assert html =~ "pending approval — nomad.task_resources_set is risk:high"
      assert html =~ "approved by you · one use · audit event recorded"
      assert html =~ "frr.bgp_neighbor_shutdown"
      assert html =~ ~s(href="/sign_up")
      assert html =~ ~s(href="/docs/security-model")
      assert html =~ ~s(href="/docs/action-packs")
    end

    test "the raw-SSH comparison renders both the desktop table and the mobile cards",
         %{conn: conn} do
      html = conn |> get(~p"/compare/raw-ssh-for-ai") |> html_response(200)

      # Both layouts ship: a wide <table> for desktop and stacked cards for
      # phones. Assert the table tag plus two concern-row labels that appear
      # in both layouts.
      assert html =~ "<table"
      assert html =~ "Both approaches run real commands"
      assert html =~ "What can the LLM run?"
      assert html =~ "Recovery story?"
    end

    test "the custom-MCP comparison renders both the desktop table and the mobile cards",
         %{conn: conn} do
      html = conn |> get(~p"/compare/custom-mcp-server") |> html_response(200)

      assert html =~ "<table"
      assert html =~ "Argument validation"
      assert html =~ "Failure modes"
    end
  end

  describe "cross-links resolve to real routes" do
    # Each page's internal cross-links must point at real, 200-resolving
    # routes — a broken nav link is a dead end for the reader and a crawl
    # gap. {page, [linked_path]} pairs assert the href is present on the
    # page AND the target resolves. (Off-site mailtos/GitHub aren't here —
    # those are covered by the outbound-link-safety tests.)
    #
    @cross_links %{
      "/docs/security-model" =>
        ~w(/security /docs/action-packs /docs/connect-an-llm /docs/signed-dispatch),
      "/docs/publishing-packs" => ~w(/packs /docs/action-packs),
      "/docs/policies-and-approvals" =>
        ~w(/docs/runbooks /docs/audit-and-siem /docs/security-model),
      "/docs/runbooks" =>
        ~w(/docs/policies-and-approvals /docs/connect-an-llm /docs/action-packs),
      "/docs/teams-and-access" =>
        ~w(/docs/sso /docs/connect-an-llm /docs/policies-and-approvals /docs/audit-and-siem),
      "/use-cases/ingress-502" =>
        ~w(/use-cases/csi-data-loss /docs/security-model /docs/action-packs),
      "/compare/raw-ssh-for-ai" => ~w(/docs/quickstart /pricing),
      "/compare/custom-mcp-server" =>
        ~w(/docs/security-model /docs/action-packs /compare/raw-ssh-for-ai)
    }

    for {page, links} <- @cross_links do
      test "#{page} links resolve", %{conn: conn} do
        html = conn |> get(unquote(page)) |> html_response(200)

        for link <- unquote(links) do
          assert html =~ ~s(href="#{link}"), "#{unquote(page)} doesn't link #{link}"

          assert conn |> get(link) |> html_response(200),
                 "#{link} (linked from #{unquote(page)}) is not 200"
        end
      end
    end
  end

  describe "home conversion + structured data" do
    test "the final CTA forwards an optional email into the sign-up flow", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # The bottom-of-page CTA is a GET form to /sign_up carrying an
      # optional email field — so a visitor who types their address lands
      # on registration pre-filled, not on a bare form.
      assert html =~ ~s(action="/sign_up")
      assert html =~ ~s(method="get")
      assert html =~ ~s(name="email")
    end

    test "the home JSON-LD graph carries Organization + SoftwareApplication + FAQPage",
         %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      graph = ld_graph(html)

      types = Enum.map(graph, & &1["@type"])
      assert "Organization" in types
      assert "SoftwareApplication" in types
      assert "FAQPage" in types

      # The SoftwareApplication carries the free-tier Offer the copy promises.
      app = Enum.find(graph, &(&1["@type"] == "SoftwareApplication"))
      assert app["offers"]["price"] == "0"
      assert app["offers"]["description"] == "Free for up to 3 runners"

      # The FAQPage's questions are real Q&A entities, not an empty shell.
      faq = Enum.find(graph, &(&1["@type"] == "FAQPage"))
      assert is_list(faq["mainEntity"]) and faq["mainEntity"] != []
      assert Enum.all?(faq["mainEntity"], &(&1["@type"] == "Question"))
    end

    test "the pricing JSON-LD graph carries a Product with two Offers + a FAQPage",
         %{conn: conn} do
      html = conn |> get(~p"/pricing") |> html_response(200)
      graph = ld_graph(html)

      product = Enum.find(graph, &(&1["@type"] == "Product"))
      assert product, "no Product node in pricing JSON-LD"

      offers = product["offers"]
      assert is_list(offers) and length(offers) == 2
      by_name = Map.new(offers, &{&1["name"], &1})
      assert by_name["Free"]["price"] == "0"
      assert by_name["Team"]["price"] == "20"

      assert Enum.any?(graph, &(&1["@type"] == "FAQPage"))
    end

    test "the pricing tier CTAs target sign-up and sales", %{conn: conn} do
      html = conn |> get(~p"/pricing") |> html_response(200)

      # Free + Team convert to registration; Enterprise routes to sales.
      assert html =~ ~s(href="/sign_up")
      assert html =~ "mailto:sales@emisar.dev"
    end
  end

  describe "legal pages content" do
    test "every legal-page TOC anchor resolves to a matching section id", %{conn: conn} do
      # The shared legal_page/1 contract: each {anchor, label} in the page's
      # TOC must have a matching <h2 id="anchor"> in the body, or the
      # in-page nav scrolls to nothing. Pull the data-toc-link anchors and
      # assert each id="…" exists.
      for route <- ~w(/privacy /terms /refund-policy) do
        html = conn |> get(route) |> html_response(200)

        anchors =
          ~r/data-toc-link="([^"]+)"/
          |> Regex.scan(html, capture: :all_but_first)
          |> List.flatten()

        assert anchors != [], "no TOC anchors on #{route}"

        for anchor <- anchors do
          assert html =~ ~s(id="#{anchor}"), "#{route} TOC anchor ##{anchor} has no section id"
        end
      end
    end

    test "each legal page carries its own title-suffix and last-updated date", %{conn: conn} do
      # {route, title, date} — the title suffix proves the right head, and
      # the date pins the right page (Refund is the only one on June 5).
      for {route, date} <- [
            {"/privacy", "June 24, 2026"},
            {"/terms", "June 4, 2026"},
            {"/refund-policy", "June 5, 2026"}
          ] do
        html = conn |> get(route) |> html_response(200)
        assert html =~ "· emisar", "missing title suffix on #{route}"
        assert html =~ "Last updated #{date}", "wrong/missing last-updated on #{route}"
      end
    end

    test "each legal page exposes its documented contact mailboxes", %{conn: conn} do
      privacy = conn |> get(~p"/privacy") |> html_response(200)
      terms = conn |> get(~p"/terms") |> html_response(200)
      refund = conn |> get(~p"/refund-policy") |> html_response(200)

      # Privacy: support (data requests) + security (disclosure).
      assert privacy =~ "mailto:support@emisar.dev"
      assert privacy =~ "mailto:security@emisar.dev"
      # Terms + Refund: support (general) + sales (enterprise).
      assert terms =~ "mailto:support@emisar.dev"
      assert terms =~ "mailto:sales@emisar.dev"
      assert refund =~ "mailto:support@emisar.dev"
      assert refund =~ "mailto:sales@emisar.dev"
    end

    test "the privacy page names only the real subprocessors", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      # The four real subprocessors must be named...
      assert html =~ "Paddle"
      assert html =~ "Postmark"
      assert html =~ "Fly.io"
      assert html =~ "Mixpanel"
    end

    test "the privacy page honestly discloses the server-side analytics posture", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "Mixpanel"
      assert html =~ "without a cookie"
      refute html =~ "no third-party trackers in the application"
      # We do NOT honor DNT/GPC (cookieless first-party isn't a sale) — the page
      # must not promise it.
      refute html =~ "Do Not Track"
      refute html =~ "Global Privacy Control"
    end

    test "the privacy page states the truthful data-handling posture", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      # The retention windows match the plans, and the two promises a
      # security product must make: no sale, no AI training on your data.
      assert html =~ "7 days"
      assert html =~ "90 days"
      assert html =~ "365 days"
      assert html =~ "do not sell"
      assert html =~ "do not use your data to train AI"
    end

    test "the terms page states the liability cap, governing law, and license characterization",
         %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)

      # The liability cap (12-month fees / US $100), Delaware governing law,
      # and the honest source-available (not OSI) license characterization.
      assert html =~ "twelve"
      assert html =~ "US $100"
      assert html =~ "Delaware"
      assert html =~ "source-available license that is not an OSI-approved"
    end

    test "the refund page links terms + pricing and states the Paddle MoR + no-pro-rate posture",
         %{conn: conn} do
      html = conn |> get(~p"/refund-policy") |> html_response(200)

      # Internal links into the related policy + pricing pages.
      assert html =~ ~s(href="/terms")
      assert html =~ ~s(href="/pricing")
      # Paddle Merchant of Record + the no-partial-month-pro-rate rule,
      # consistent with the Terms billing section.
      assert html =~ "Merchant of Record"
      assert html =~ "pro-rate"
    end
  end

  describe "sitemap.xml hygiene" do
    test "lists no private app, auth, or machine-API routes", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      # The sitemap is the public, indexable surface only. A leaked /app,
      # sign-in, SCIM, REST-API, or OAuth path would invite crawlers (and
      # scanners) at the authenticated control plane.
      for private <- ~w(/app /sign_in /scim /api /oauth) do
        refute body =~ "#{private}</loc>", "sitemap leaks a private route: #{private}"
      end
    end

    test "every <loc> is an absolute https://emisar.dev URL", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      locs = Regex.scan(~r{<loc>([^<]+)</loc>}, body, capture: :all_but_first)
      assert locs != []

      for [loc] <- locs do
        assert String.starts_with?(loc, "https://emisar.dev"), "non-absolute sitemap loc: #{loc}"
      end
    end

    test "marks every URL changefreq weekly with no lastmod", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)
      assert body =~ "<changefreq>weekly</changefreq>"
      refute body =~ "<lastmod>"
    end

    test "lists the /zero-trust page", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)
      assert body =~ "https://emisar.dev/zero-trust</loc>"
    end

    test "ignores junk query params and returns the same XML", %{conn: conn} do
      clean = conn |> get(~p"/sitemap.xml") |> response(200)
      junked = conn |> get("/sitemap.xml?utm_source=x&foo=1") |> response(200)
      assert junked == clean
    end
  end

  describe "install scripts match their documented endpoints" do
    test "the install-mcp.sh URL quoted on /docs/connect-an-llm is the live endpoint",
         %{conn: conn} do
      # The docs page tells operators to `curl … /install-mcp.sh | sudo bash`;
      # that exact URL must resolve to the real script, never a 404/HTML —
      # a `curl | bash` integrity guarantee.
      html = conn |> get(~p"/docs/connect-an-llm") |> html_response(200)
      assert html =~ "https://emisar.dev/install-mcp.sh"

      conn = get(conn, ~p"/install-mcp.sh")
      assert response(conn, 200) =~ "#!/"
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "shellscript"
    end
  end

  # Pull every external (`href="http…"`) anchor out of rendered HTML so a
  # test can assert the whole set carries the safe-rel pair, not just the
  # one link it happened to name.
  defp external_links(html) do
    ~r{<a\s[^>]*href="https?://[^>]*>}
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
  end

  # Parse the page's bespoke JSON-LD @graph (home / pricing carry a
  # `{"@graph": [...]}` block, html_safe-escaped). Returns the list of
  # graph nodes so a test can assert their @types and contents — parsing,
  # not grepping, proves it's valid structured data.
  defp ld_graph(html) do
    ~r{<script type="application/ld\+json"[^>]*>(.*?)</script>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [raw] ->
      case raw |> String.trim() |> Jason.decode() do
        {:ok, %{"@graph" => graph}} when is_list(graph) -> graph
        _ -> []
      end
    end)
  end
end
