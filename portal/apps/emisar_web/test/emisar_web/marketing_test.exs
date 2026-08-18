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
    /docs/connect-a-cli-client
    /docs/publishing-packs
    /docs/pack-registry
    /docs/policies-and-approvals
    /docs/runbooks
    /docs/authentication
    /docs/teams-and-access
    /docs/sso
    /docs/integrations/okta
    /docs/integrations/entra
    /docs/integrations/jumpcloud
    /docs/integrations/keycloak
    /docs/integrations/google-workspace
    /docs/scim
    /docs/runners
    /docs/deployment
    /docs/audit-and-siem
    /docs/host-install
    /docs/containers
    /docs/kubernetes
    /docs/nomad
    /docs/autoscaling-fleets
    /docs/runs
    /docs/keys
    /docs/runner-cli
    /docs/billing
    /docs/limits
    /docs/upgrades
    /docs/credentials
    /docs/pack-updates
    /docs/network-requirements
    /docs/troubleshooting
    /docs/security-incidents
    /docs/architecture
    /changelog
    /about
    /support
    /privacy
    /terms
    /refund-policy
    /packs
    /packs/postgres
    /packs/cassandra
    /use-cases
    /use-cases/cassandra-migration
    /use-cases/csi-data-loss
    /use-cases/ingress-502
    /compare/raw-ssh-for-ai
    /compare/custom-mcp-server
    /compare/copy-paste-ai-ops
    /zero-trust
    /how-it-works
    /trust
    /dpa
    /docs/mcp-reference
    /guides
    /guides/how-emisar-works
    /guides/give-ai-agents-safe-production-access
    /guides/prompt-injection-for-ops-teams
  )

  for route <- @routes do
    test "GET #{route} renders 200", %{conn: conn} do
      conn = get(conn, unquote(route))
      assert html_response(conn, 200)
    end
  end

  describe "route coverage parity (no marketing page skips the battery)" do
    # @routes is hand-maintained, so a page added to the router without being
    # added here skips the render-200 + CSP-nonce + indexability battery
    # silently — exactly how 9 docs pages (host-install, kubernetes, nomad,
    # autoscaling-fleets, limits, runs, keys, runner-cli, billing) drifted out
    # of it until the 2026-07-23 ship review. The router derivation is shared
    # with MarketingStructuralTest's guard (EmisarWeb.MarketingRoutes) so the
    # two can't disagree about what the public surface is.
    test "every static marketing page is in @routes" do
      missing =
        MapSet.difference(EmisarWeb.MarketingRoutes.static_html_paths(), MapSet.new(@routes))

      assert MapSet.size(missing) == 0,
             "marketing pages live in the router but are missing from @routes — add them so " <>
               "the render + CSP + indexability battery covers them: " <>
               inspect(Enum.sort(MapSet.to_list(missing)))
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
          /use-cases/cassandra-migration
          /use-cases/ingress-502
          /compare/raw-ssh-for-ai
          /compare/custom-mcp-server
          /compare/copy-paste-ai-ops
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
    # font-bold …" then the scale (which carries the tighter tracking + the
    # display leading). (Home appends layout classes — the rise-in animation
    # + a max-width — after the scale, so match the class prefix, not a
    # closed attribute — like the docs line.)
    home = conn |> get(~p"/") |> html_response(200)

    assert home =~
             ~s(<h1 class="text-balance font-display font-bold text-zinc-50 text-4xl/[1.1] tracking-[-0.035em] sm:text-6xl/[1.1] md:text-7xl/[1.1])

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
    assert html =~ "Apache-2.0"
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
    # The three real stories are featured and linked from the hub. The weaker
    # "real-shape" datastore walkthroughs were cut from the war stories; they
    # live on as pack-supporting pages, reachable from their packs and docs.
    assert html =~ "How ChatGPT Sol helped move Cassandra from GCP to bare metal"
    assert html =~ "≈6.3 TiB dataset"
    assert html =~ "12 app jobs cut over"
    refute html =~ "14.28 TiB backup"
    assert html =~ "The 33-hour wipe"
    assert html =~ "The fleet-wide 502 that no backend was causing"
    assert html =~ ~s(href="/use-cases/cassandra-migration")
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
    assert length(Regex.scan(~r/Dedicated Slack support channel/, html)) == 2
    refute html =~ "Priority support"
    refute html =~ "99.9% uptime SLA"
    refute html =~ "On-prem / self-hosted option"
  end

  test "public capability claims follow the MCP, billing, and audit contracts", %{conn: conn} do
    home = conn |> get(~p"/") |> html_response(200)
    tool_count = length(EmisarWeb.MCP.SchemaRegistry.tool_names())

    assert home =~ "emisar MCP connected · #{tool_count} tools"
    refute home =~ "84 tools"

    pricing = conn |> get(~p"/pricing") |> html_response(200)

    assert [siem_row] =
             Regex.run(
               ~r/<tr>\s*<td[^>]*>SIEM export<\/td>(.*?)<\/tr>/s,
               pricing,
               capture: :all_but_first
             )

    assert siem_row =~ ">—</td>"
    assert length(Regex.scan(~r/hero-check/, siem_row)) == 2
    assert home =~ "Audit trail; SIEM export on Team+"

    trust = conn |> get(~p"/trust") |> html_response(200)
    assert trust =~ "Runner journal:"
    assert trust =~ "retained runner journal&#39;s chain"
    assert trust =~ "privileged host operator"
    assert trust =~ "replace or truncate the entire local journal"
    assert trust =~ "Portal audit:"
    refute trust =~ "catches any edited or missing line"
  end

  test "journal verification claims preserve the retained-evidence boundary", %{conn: conn} do
    for route <- [
          ~p"/docs/runner-cli",
          ~p"/docs/audit-and-siem",
          ~p"/docs/security-model",
          ~p"/docs/security-incidents",
          ~p"/guides/how-emisar-works"
        ] do
      text = conn |> get(route) |> html_response(200) |> squish()

      assert text =~ "retained journal or retained suffix",
             "#{route} does not scope verification to retained evidence"

      assert text =~ "replace or truncate the entire local journal",
             "#{route} does not state the whole-journal blind spot"

      refute text =~ "truncate the tail and re-chain"
      refute text =~ "re-chain a forgery"
    end
  end

  test "redaction copy describes pattern processing rather than perfect secret detection", %{
    conn: conn
  } do
    for route <- [
          ~p"/security",
          ~p"/trust",
          ~p"/docs/quickstart",
          ~p"/guides/give-ai-agents-safe-production-access",
          ~p"/dpa"
        ] do
      text = conn |> get(route) |> html_response(200) |> squish()

      refute text =~ "Secrets redacted before egress"
      refute text =~ "Secrets are redacted on the host"
      refute text =~ "redacts secrets before output leaves"
    end

    security = conn |> get(~p"/security") |> html_response(200) |> squish()
    assert security =~ "A novel secret shape can still pass a pattern-based filter"
  end

  test "pricing page carries a monthly/annual toggle with both Team prices", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)

    # The toggle (a plain-JS class swap — no LiveSocket on marketing) plus both
    # per-cycle Team prices are server-rendered; the annual block starts hidden.
    assert html =~ ~s(data-cycle-toggle)
    assert html =~ ~s(data-cycle="year")
    assert html =~ "$20"
    assert html =~ "/ runner / mo"
    assert html =~ "$200"
    assert html =~ "/ runner / yr"
    assert html =~ "2 months free"
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
    assert html =~ "MCPTool(emisar__*)"
    assert html =~ ~s(default_tools_approval_mode = "approve")
  end

  test "docs states the supported deployment boundary", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "supported product is the hosted emisar control plane today"
    refute html =~ "Run the control plane in your own VPC"
  end

  test "containers docs page covers visibility, the official image, identity, and the fleet shapes",
       %{conn: conn} do
    html = conn |> get(~p"/docs/containers") |> html_response(200)

    # The honest core: a containerized runner acts on its own namespace.
    assert html =~ "act on what its own namespace can reach"
    # The official image and its FROM-based extension mechanic.
    assert html =~ "ghcr.io/andrewdryga/emisar-runner"
    assert html =~ "emisar pack install"
    # The custom-image fallback flag and identity persistence.
    assert html =~ "--no-service"
    assert html =~ "/var/lib/emisar/token.json"
    # Fleet relabeling via env, without a config mount.
    assert html =~ "EMISAR_GROUP"
    assert html =~ "EMISAR_RUNNER_ID"
    # Fleet templates need a reusable key, not the dashboard's single-use one.
    assert html =~ "reusable enrollment key"
    assert html =~ ~s(href="/docs/runners#enrollment-keys")
    # The three shapes.
    assert html =~ "DaemonSet"
    assert html =~ "system"
    assert html =~ "sidecar"
  end

  test "kubernetes docs page sets a per-fleet group and the node name as the identity",
       %{conn: conn} do
    html = conn |> get(~p"/docs/kubernetes") |> html_response(200)

    # The DaemonSet relabels via env, not a mounted config: a per-fleet
    # dispatch-targeting group, and the node name as the runner identity.
    assert html =~ "EMISAR_GROUP"
    assert html =~ "EMISAR_RUNNER_ID"
    assert html =~ "spec.nodeName"
  end

  test "SSO docs page covers login setup and the subject-not-email binding", %{conn: conn} do
    html = conn |> get(~p"/docs/sso") |> html_response(200)

    assert html =~ "Single sign-on"
    # Links to the directory-sync half.
    assert html =~ "directory sync"
    # The registered callback the operator must wire up.
    assert html =~ "/sign_in/sso/callback"
    # The headline security posture (must match the built behavior).
    assert html =~ "subject, never by email"
    # The per-provider consoles moved to their own guides; this page routes there.
    for path <- ~w(okta entra jumpcloud keycloak google-workspace) do
      assert html =~ "/docs/integrations/#{path}"
    end

    assert html =~ "Verified against a live Okta Integrator org on July 27, 2026."
    assert html =~ "Verified against a live JumpCloud tenant on July 31, 2026."

    # The oid cross-reference goes straight to the Entra guide, not the
    # one-line provider bullet on this same page.
    refute html =~ "/docs/sso#entra"
  end

  test "each provider guide carries its own console walkthrough", %{conn: conn} do
    okta = conn |> get(~p"/docs/integrations/okta") |> html_response(200)
    # Both halves live on one page now — sign-in and the directory that follows it.
    assert okta =~ "Single sign-on"
    assert okta =~ "Directory sync"
    assert okta =~ "/images/docs/sso/okta-oidc-create.webp"
    assert okta =~ "/images/docs/sso/okta-scim-verified.webp"

    keycloak = conn |> get(~p"/docs/integrations/keycloak") |> html_response(200)
    # The verified Keycloak path is exact and backed by privacy-safe captures.
    assert keycloak =~ "Keycloak 26.7"
    assert keycloak =~ "Client authentication"
    assert keycloak =~ "Require PKCE"
    assert keycloak =~ "/images/docs/sso/keycloak-client-secret.webp"

    entra = conn |> get(~p"/docs/integrations/entra") |> html_response(200)
    # The two settings that carry the whole Entra integration.
    assert entra =~ "oid"
    assert entra =~ "objectId"

    jumpcloud = conn |> get(~p"/docs/integrations/jumpcloud") |> html_response(200)
    # JumpCloud is the one provider whose single app does both jobs.
    assert jumpcloud =~ "Export users to this app"

    google = conn |> get(~p"/docs/integrations/google-workspace") |> html_response(200)
    assert google =~ "Internal"
    assert google =~ "accounts.google.com"
  end

  test "SCIM docs page covers directory sync, deprovisioning, and group mapping",
       %{conn: conn} do
    html = conn |> get(~p"/docs/scim") |> html_response(200)

    # The SCIM base URL the operator must wire up.
    assert html =~ "/scim/v2"
    # Deprovisioning suspends, never deletes (must match the built behavior).
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
    assert html =~
             ">curl --proto &#39;=https&#39; --proto-redir &#39;=https&#39; --globoff -fsSL https://emisar.dev/install.sh | sudo bash</div>"

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

  test "healthz returns process liveness and the running version", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    version = EmisarWeb.AppVersion.version()
    revision = EmisarWeb.AppVersion.revision()

    assert json_response(conn, 200) == %{
             "revision" => revision,
             "status" => "ok",
             "version" => version
           }
  end

  test "readyz returns readiness when the DB is reachable", %{conn: conn} do
    conn = get(conn, ~p"/readyz")
    version = EmisarWeb.AppVersion.version()
    revision = EmisarWeb.AppVersion.revision()

    assert json_response(conn, 200) == %{
             "revision" => revision,
             "status" => "ok",
             "version" => version
           }
  end

  test "health probes are never cached", %{conn: conn} do
    for path <- [~p"/healthz", ~p"/readyz"] do
      conn = get(conn, path)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "health probes are reachable with no session/auth/CSRF", %{conn: conn} do
    # The route rides the bare :api pipeline (no fetch_session / fetch_current_user
    # / protect_from_forgery), so infrastructure probes need no cookies.
    version = EmisarWeb.AppVersion.version()
    revision = EmisarWeb.AppVersion.revision()

    for path <- [~p"/healthz", ~p"/readyz"] do
      conn = get(conn, path)

      assert json_response(conn, 200) == %{
               "revision" => revision,
               "status" => "ok",
               "version" => version
             }

      refute conn.assigns[:current_user]
      assert conn.req_cookies == %{}
    end
  end

  test "health probes only answer GET", %{conn: conn} do
    for path <- ["/healthz", "/readyz"] do
      conn = post(conn, path)
      assert conn.status == 404
    end
  end

  # Emisar.Billing owns what a plan grants — billing_live renders plan.features
  # straight from it — while /pricing types the same list by hand. They had
  # already drifted: Team's "Audit export (CSV + SIEM)" shipped in the product
  # and appeared in the console and in /docs/billing, but not on the page where
  # someone decides to buy.
  #
  # The page may say MORE than the contract: an uptime target and automated
  # invoices are marketing's to promise and are not plan entitlements. It may
  # not say less.
  describe "pricing reflects the plan contract" do
    test "every feature Billing grants a plan appears on that plan's card", %{conn: conn} do
      html = conn |> get(~p"/pricing") |> html_response(200)

      missing =
        for {_id, plan} <- Emisar.Billing.plans(),
            feature <- plan.features,
            # Enterprise's "Everything in Team" is a reference to another card,
            # not a feature line of its own.
            feature != "Everything in Team",
            not String.contains?(html, feature),
            do: "#{plan.name}: #{feature}"

      assert missing == [],
             "/pricing omits plan features Emisar.Billing grants: #{inspect(missing)}"
    end

    test "the limits Billing enforces are the limits the page advertises", %{conn: conn} do
      html = conn |> get(~p"/pricing") |> html_response(200)
      free = Emisar.Billing.plan("free")
      team = Emisar.Billing.plan("team")

      assert html =~ "#{free.runners_limit} runners"
      assert html =~ "#{free.audit_retention_days}-day audit retention"
      assert html =~ "#{team.runners_limit} runners"
      assert html =~ "#{team.audit_retention_days}-day audit retention"
    end
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

      # The footer CTA books the walkthrough calendar directly, and that
      # off-site anchor is held to the same tab-safety contract.
      assert html =~ "Book a walkthrough"

      calendar_href = ~s(href="https://cal.com/andrew-dryga/emisar")
      calendar_link = Enum.find(external_links(html), &(&1 =~ calendar_href))

      assert calendar_link, "the /security CTA does not link the walkthrough calendar"
      assert calendar_link =~ ~s(target="_blank")
      assert calendar_link =~ ~s(rel="noopener noreferrer")
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
    for route <-
          ~w(/changelog /about /docs/publishing-packs /docs/security-model /docs/signed-dispatch /use-cases/csi-data-loss) do
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
      # dead end. Pull the on-page hrefs and GET each documentation target.
      for path <- ~w(
            /docs/quickstart
            /docs/connect-an-llm
            /docs/connect-a-cli-client
            /docs/policies-and-approvals
            /docs/runbooks
            /docs/authentication
            /docs/teams-and-access
            /docs/sso
    /docs/integrations/okta
    /docs/integrations/entra
    /docs/integrations/jumpcloud
    /docs/integrations/keycloak
    /docs/integrations/google-workspace
            /docs/scim
            /docs/runners
            /docs/audit-and-siem
            /docs/action-packs
            /docs/publishing-packs
            /docs/pack-registry
            /docs/security-model
            /docs/signed-dispatch
            /pricing
          ) do
        assert index =~ ~s(href="#{path}"), "docs index doesn't link #{path}"
        assert conn |> get(path) |> html_response(200), "docs card target #{path} is not 200"
      end
    end

    test "every guide on the guides index also appears on the docs index", %{conn: conn} do
      guides_index = conn |> get(~p"/guides") |> html_response(200)
      docs_index = conn |> get(~p"/docs") |> html_response(200)

      guide_paths =
        ~r/href="(\/guides\/[^"#?]+)"/
        |> Regex.scan(guides_index, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      assert guide_paths != []

      for path <- guide_paths do
        assert docs_index =~ ~s(href="#{path}"), "docs index doesn't link #{path}"
      end
    end

    test "the docs hub offers a support mailbox", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)
      assert html =~ ~s(mailto:support@emisar.dev)
    end

    test "the docs index server-renders every DocsNav page under its group", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)

      # The filter only hides rows, so the crawlable index must carry the whole
      # tree before any JS runs.
      for page <- EmisarWeb.DocsNav.flat() do
        assert html =~ ~s(href="#{page.path}"), "docs index doesn't link #{page.path}"
      end

      group_labels =
        ~r/data-docs-group="([^"]+)"/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      # "Team & account" renders escaped in the attribute.
      expected = Enum.map(EmisarWeb.DocsNav.groups(), &String.replace(&1.label, "&", "&amp;"))

      assert group_labels == expected
      refute "Integrations" in group_labels

      # One filterable block per section, so a group with subgroups hides them
      # independently.
      sections = Enum.sum_by(EmisarWeb.DocsNav.groups(), &length(&1.sections))
      assert length(String.split(html, "data-docs-subgroup")) - 1 == sections
    end

    test "the docs index renders the display-only subgroup headings", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)

      for label <- ["Access", "Identity concepts", "Provider guides", "Account"] do
        assert html =~ ~r{<h3[^>]*>\s*#{label}\s*</h3>},
               "docs index is missing the #{label} subgroup heading"
      end
    end

    test "the docs index renders provider logos as emisar accent marks", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)

      marks =
        ~r/<span[^>]+data-provider-mark="[^"]+"[^>]*>/
        |> Regex.scan(html)
        |> List.flatten()

      assert length(marks) == 5

      for mark <- marks do
        assert mark =~ "docs-provider-mark"
        assert mark =~ "bg-brand-400/80"
        assert mark =~ "--provider-mark:"
        refute mark =~ "bg-white"
      end

      refute html =~ ~r/<img[^>]+src="\/images\/logos\//
    end

    test "a subgrouped docs page keeps a three-part breadcrumb and a subgrouped sidebar",
         %{conn: conn} do
      html = conn |> get(~p"/docs/sso") |> html_response(200)

      # The subgroup is wayfinding in the rail only — the breadcrumb stays
      # Docs → top-level group → page.
      assert html =~ "Identity concepts"
      assert html =~ "Provider guides"
      assert html =~ "Team &amp; account"

      crumbs =
        ~r/<nav[^>]+aria-label="Breadcrumb".*?<\/nav>/s
        |> Regex.run(html)
        |> hd()

      assert crumbs =~ "Team &amp; account"
      refute crumbs =~ "Identity concepts"
      refute crumbs =~ "Provider guides"
    end

    test "the docs index filter is labelled, searchable, and has an empty state", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(200)

      assert html =~ ~s(id="docs-filter")
      assert html =~ ~s(aria-label="Filter documentation")
      assert html =~ ~s(id="docs-filter-empty")
      assert html =~ ~s(role="status")

      # Every row carries the metadata the filter matches on: title,
      # description, group, subgroup, and the page's DocsNav keywords.
      terms =
        ~r/data-docs-page="([^"]+)"/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      # One row per DocsNav page, plus the hosting & plans row.
      assert length(terms) == length(EmisarWeb.DocsNav.flat()) + 1

      okta = Enum.find(terms, &String.contains?(&1, "okta end to end"))
      assert okta =~ "team &amp; account"
      assert okta =~ "provider guides"
      assert okta =~ "scim"
    end
  end

  describe "support" do
    test "publishes stable support and security channels without asking for secrets", %{
      conn: conn
    } do
      html = conn |> get(~p"/support") |> html_response(200)

      assert html =~ "mailto:support@emisar.dev"
      assert html =~ "mailto:security@emisar.dev"
      assert html =~ "https://status.emisar.dev"
      assert html =~ "Do not send API keys"
    end

    test "the sitemap lists the public support URL", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)
      assert body =~ "https://emisar.dev/support</loc>"
    end
  end

  describe "per-page content sections" do
    # Each marketing page renders its own documented sections. These assert
    # the STABLE, apostrophe-free headings/copy that the page actually
    # renders (read off the templates), so a section silently disappearing
    # surfaces — without pinning brittle full sentences a copy tweak would
    # break.

    test "the how-emisar-works guide explains both enforcement planes and their limits", %{
      conn: conn
    } do
      html = conn |> get(~p"/guides/how-emisar-works") |> html_response(200)

      assert html =~ "What the agent can do"
      assert html =~ "Following one request"
      assert html =~ "Audit, redaction, and privileges"
      assert html =~ "The MCP surface"
      assert html =~ "Signed dispatch"

      assert html =~
               "A customer-authorized MCP bridge signed the dispatch frame with its locally held Ed25519 key."

      assert html =~
               "The runner opens an outbound TLS WebSocket and exposes no inbound listener; commands return through that established connection."

      assert html =~ "Private packs"
      assert html =~ "not a VM, container, or kernel sandbox"
      assert html =~ "emisar.admin.access.diagnose"
      assert html =~ "fixed release-RPC script"
      assert html =~ "linux-core/actions/systemctl_restart.yaml (trimmed)"
      assert html =~ "linux.journalctl"
      assert html =~ "1. read logs — run_action input"
      assert html =~ "2. restart service — run_action input"
      assert html =~ "3. verify service — run_action input"
      assert html =~ "linux.systemctl_status"
    end

    test "the deployment guide attributes signed dispatch to the bridge key", %{conn: conn} do
      html = conn |> get(~p"/docs/deployment") |> html_response(200) |> squish()

      assert html =~
               "A customer-authorized MCP bridge signed the dispatch frame with its locally held Ed25519 key."

      refute html =~ "a human&#39;s signature"
    end

    test "the home hero aligns its peer verdict chips", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # Three Allowed verdicts plus the Approved verdict share one visual column.
      assert length(Regex.scan(~r/w-\[5\.5rem\] flex-none justify-center/, html)) == 4
      refute html =~ "w-[6.25rem]"
    end

    test "the home catalog snippet matches the published linux.systemctl_status contract", %{
      conn: conn
    } do
      # The pillar-1 example claims to BE the pack's source file, so its
      # decision-changing fields are bound to the bundled catalog (itself
      # gate-verified against packs/) — the page can never show a contract
      # that doesn't exist.
      catalog =
        :emisar
        |> Application.app_dir("priv/packs/catalog.json")
        |> File.read!()
        |> Jason.decode!()

      pack = Enum.find(catalog["packs"], &(&1["id"] == "linux-core"))
      action = Enum.find(pack["actions"], &(&1["id"] == "linux.systemctl_status"))
      [%{"name" => arg_name, "validation" => %{"pattern" => pattern}}] = action["args"]
      %{"binary" => binary, "argv" => argv} = action["command"]

      html = conn |> get(~p"/") |> html_response(200)
      text = catalog_snippet_text(html)

      assert text =~ "id: #{action["id"]}"
      assert text =~ ~s(title: "#{action["title"]}")
      assert text =~ "risk: #{action["risk"]}"
      assert text =~ "name: #{arg_name}"
      assert text =~ ~s(pattern: "#{pattern}")
      assert text =~ "binary: #{binary}"
      assert text =~ "argv: [" <> Enum.map_join(argv, ", ", &~s("#{&1}")) <> "]"
    end

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
      assert html =~ "20 built-in patterns"
      assert html =~ "RFC 6238"
      assert html =~ "read-only audit-export token"

      assert html =~
               "A customer-authorized MCP bridge signed the dispatch frame with its locally held Ed25519 key."

      assert html =~ "MCP bridge keys are short-lived and rotate themselves"

      assert html =~
               "Runner output is redacted before leaving the host; Emisar retains the resulting redacted output in audit log."

      assert html =~ "Verification covers the retained"
      assert html =~ "privileged host operator"
      refute html =~ "action a real person signed"
      refute html =~ "Recorded byte-for-byte"

      # The honest not-affiliated note (this is a security product; the
      # framing is "we implement it", never "they endorse us").
      assert html =~ "Not affiliated with or endorsed by Anthropic"

      # The approval-loop cast — REAL console moments from one live-driven
      # take, not mocks: request, decision note, approval, run, and audit
      # trail as an animated storyboard whose no-JS render carries every frame.
      assert html =~ "Watch one risky action cross the gate."
      assert html =~ "data-console-cast"
      assert html =~ "/images/screenshots/loop/approval-pending.webp"
      assert html =~ "/images/screenshots/loop/approval-note.webp"
      assert html =~ "/images/screenshots/loop/approval-approved.webp"
      assert html =~ "/images/screenshots/loop/run-success.webp"
      assert html =~ "/images/screenshots/loop/audit-trail.webp"
      assert html =~ "/images/screenshots/loop/audit-event.webp"
    end

    test "the /trust page surfaces release integrity with the real verify commands", %{conn: conn} do
      # The procurement-facing answer to "how do I verify the binary I pipe into
      # sudo bash" — SLSA provenance + checksums, with the ACTUAL commands that
      # verify against our published releases (gh attestation verify succeeds for
      # runner-v0.7.4 --owner andrewdryga; sha256sum -c SHA256SUMS passes).
      html = conn |> get(~p"/trust") |> html_response(200)

      assert html =~ "Release integrity"
      assert html =~ "SLSA Build Level 2 provenance"
      refute html =~ "SLSA-3 build provenance"
      assert html =~ "gh attestation verify"
      assert html =~ "--owner andrewdryga"
      assert html =~ "sha256sum -c SHA256SUMS"
    end

    test "the /trust page states assurance and insurance limits precisely", %{
      conn: conn
    } do
      html = conn |> get(~p"/trust") |> html_response(200)

      assert html =~ "Security controls you can verify"
      assert html =~ "Security review material is available now"
      assert html =~ "SOC 2 Type II audit preparation is underway"
      assert html =~ "examination is not complete"
      assert html =~ "certificate of insurance is available on request"
      assert html =~ "Team and Enterprise plans"
      refute html =~ "emisar is SOC 2 certified"
    end

    test "the /trust page documents production and delivery controls", %{conn: conn} do
      html = conn |> get(~p"/trust") |> html_response(200)

      assert html =~ "Production infrastructure"
      assert html =~ "Application instances have no public IP addresses"
      assert html =~ "validating chain of trust"
      assert html =~ "emisar.dev"
      assert html =~ "point-in-time recovery"
      assert html =~ "Change control &amp; software delivery"
      assert html =~ "Pull requests run with read-only permissions"
      assert html =~ "CycloneDX SBOM"
      assert html =~ "immutable digest"
      assert html =~ "Confirm\n            &amp; Apply"
      assert html =~ "out-of-scope hosts from current fleet and dispatch surfaces"
      refute html =~ "members never see out-of-scope hosts"
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

    test "the cloud LLM page renders the OAuth connector setup for Claude and ChatGPT",
         %{conn: conn} do
      html = conn |> get(~p"/docs/connect-an-llm") |> html_response(200)

      # Current ChatGPT Developer-mode setup path: OAuth, no static token.
      # Developer mode lives under Settings → Security and login (also linked at
      # the bottom of Settings → Plugins); the connector is created under Settings
      # → Plugins; switching Permissions to "Allow all actions" drops the prompts.
      assert html =~ "Settings → Security and login"
      assert html =~ "Settings → Plugins"
      assert html =~ "Developer mode"
      assert html =~ "Available on all ChatGPT plans"
      assert html =~ "Server URL"
      assert html =~ "I understand and want to continue"
      assert html =~ "Allow low-risk actions"
      assert html =~ "Allow all actions"

      # Claude's connector block on the same page.
      assert html =~ "Settings → Connectors"
      assert html =~ "Connector name"
      assert html =~ "OAuth Client ID / Client Secret"
      assert html =~ "Read-only tools"
      assert html =~ "Write/delete tools"
      assert html =~ "Always allow"
      assert html =~ "click <strong>Create</strong>"
      assert html =~ "choose <strong>OAuth</strong>"
      assert html =~ "Use it from a <strong>new chat</strong>"
      assert html =~ "choose <strong>More</strong>"
      assert html =~ "conversation context"
      assert html =~ "choose <strong>Refresh</strong>"
    end

    test "the CLI-client page renders every stdio client config block", %{conn: conn} do
      html = conn |> get(~p"/docs/connect-a-cli-client") |> html_response(200)

      # The stdio-bridge config for each supported desktop/CLI client.
      assert html =~ "claude_desktop_config.json"
      assert html =~ ".cursor/mcp.json"
      assert html =~ "claude mcp add emisar"
      assert html =~ ".gemini/settings.json"
      assert html =~ "mcp_servers.emisar"
      assert html =~ "grok mcp add emisar"
      assert html =~ "EMISAR_CLIENT=claude-code"
      assert html =~ "EMISAR_CLIENT=grok"
      assert html =~ "MCPTool(emisar__*)"
      assert html =~ ~s(default_tools_approval_mode = "approve")
      assert html =~ ~s("EMISAR_CLIENT": "claude-desktop")
      assert html =~ ~s("EMISAR_CLIENT": "cursor")
      assert html =~ ~s(EMISAR_CLIENT = "codex")
      # Zed nests under context_servers (not mcpServers) — its own shape.
      assert html =~ ".config/zed/settings.json"
      assert html =~ "context_servers"
      assert html =~ ~s("EMISAR_CLIENT": "zed")
    end

    test "the changelog renders its entries and the feed links", %{conn: conn} do
      html = conn |> get(~p"/changelog") |> html_response(200)

      # The data-driven release entries (EmisarWeb.Changelog) — assert labels.
      assert html =~ "The foundation"
      assert html =~ "Public beta control plane"
      assert html =~ "Bridge-attested signed dispatch"
      assert html =~ "requires Claude and Codex to pass the same held-out contract"
      refute html =~ "requires Claude, Codex, and Gemini"
      assert html =~ "The marketing site, rebuilt"
      assert html =~ "More reliable background work and a cleaner runner setup"
      assert html =~ "Annual billing, Team-owned SSO, and safer input handling"
      assert html =~ "Hardened hosting, safer releases, and a public status page"
      assert html =~ "Stronger delivery controls and clearer trust evidence"
      assert html =~ "Durable execution and a tighter MCP boundary"
      assert html =~ "Cleaner setup and reliable release publication"
      assert html =~ "Exact action validation and stronger UI proof"
      assert html =~ "Versioned registry schemas for append-only publishing"
      assert html =~ "Stricter runner results and cleaner settings"
      assert html =~ "Reconnect-safe runs and a clearer agents list"
      assert html =~ "Reliable runner startup and clearer MCP failures"
      assert html =~ "Upgrade-safe runners and honest fleet alarms"
      assert html =~ "Leaner MCP results and a hardened pack catalog"
      assert html =~ "Database-enforced tenant isolation and steadier dispatch"
      assert html =~ "Browser-approved agent connect and pack lifecycle control"
      assert html =~ "The MCP installer preserves a commented Zed config"
      assert html =~ "Real-agent MCP evals and symptom-language action search"
      assert html =~ "Trust-aware action discovery and clean runner re-enrollment"
      assert html =~ "Live run output for agents and a tighter pack-argument boundary"
      assert html =~ "Runner identity by hostname and pack behavior proven on real services"
      assert html =~ "Staged runbooks and hardened enterprise identity"
      assert html =~ "Self-rotating runner credentials and a harder execution boundary"

      assert html =~
               "A vanished runbook, a deny that matched nothing, and a session that would not end"

      assert html =~ "One runbook, one unpublished change, and a diff before you publish"
      assert html =~ "Large runbooks finish, and every result stays readable"
      assert html =~ "Pack CI runs only what changed"

      # Product release tags — the commit history, the tags, and the changelog
      # all line up (newest and oldest both rendered).
      assert html =~ "v0.1.0"
      assert html =~ "v0.24.0"
      assert html =~ "v0.24.1"
      assert html =~ "v0.25.0"
      assert html =~ "v0.25.1"
      assert html =~ "v0.25.2"
      assert html =~ "v0.25.3"
      assert html =~ "v0.25.4"
      assert html =~ "v0.26.0"
      assert html =~ "v0.27.0"
      assert html =~ "v0.28.0"
      assert html =~ "v0.29.0"
      assert html =~ "v0.30.0"
      assert html =~ "v0.31.0"
      assert html =~ "v0.31.1"
      assert html =~ "v0.32.0"
      assert html =~ "v0.33.0"
      assert html =~ "v0.34.0"
      assert html =~ "v0.35.0"
      assert html =~ "v0.36.0"
      assert html =~ "v0.37.0"
      assert html =~ "v0.38.0"
      assert html =~ "v0.39.0"
      assert html =~ "v0.40.0"
      assert html =~ "v0.41.0"
      assert html =~ "v0.41.1"
      assert html =~ "v0.15.0"

      # The first-party RSS feed, the repo, and the "see all" out-link.
      assert html =~ "/changelog.xml"
      assert html =~ "https://github.com/andrewdryga/emisar/releases"
      assert html =~ "See all releases on GitHub"
    end

    test "the marketing footer shows the app version and the co:op attribution",
         %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # The footer reads the running app's version (single source: portal/VERSION,
      # bumped by /ops-release), so assert the shape, not a pinned number.
      assert html =~ "built with"
      assert html =~ ~s(href="https://coop.dryga.com/")
      assert html =~ "co:op"
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

    test "the cloud LLM page renders the remote MCP endpoint", %{conn: conn} do
      html = conn |> get(~p"/docs/connect-an-llm") |> html_response(200)

      # The remote MCP server URL an operator pastes into the connector; no
      # REST-style path is implied.
      assert html =~ "https://emisar.dev/api/mcp/rpc"
      refute html =~ "GET /api/mcp/runners"
    end

    test "the CLI-client page renders the verbatim bridge install command", %{conn: conn} do
      html = conn |> get(~p"/docs/connect-a-cli-client") |> html_response(200)

      # The bridge install command an operator copies verbatim. (The install URL
      # is wrapped in a syntax-highlight span, so assert the URL and the
      # `| sudo bash` tail as separate stable pieces, not one contiguous literal.)
      assert html =~ "curl --proto &#39;=https&#39;"
      assert html =~ "https://emisar.dev/install-mcp.sh"
      assert html =~ "| sudo bash"
    end

    test "the CLI-client page explains what the sign-in grants", %{conn: conn} do
      html = conn |> get(~p"/docs/connect-a-cli-client") |> html_response(200)

      # The security posture of the key the bridge carries: it acts as its owner
      # and inherits their scope — the same claim the cloud connect page makes.
      assert html =~ "What the sign-in grants"
      assert html =~ "the agent acts as you"
      assert html =~ "inherits its operator"
    end

    test "the quickstart renders the install command pinned to the TLS endpoint", %{conn: conn} do
      html = conn |> get(~p"/docs/quickstart") |> html_response(200)

      # The one-command install — the URL must be the literal TLS endpoint
      # (the same one /install.sh serves), and "read it first" links it.
      # The command wraps across a `\`-newline with the enrollment key
      # interpolated, so assert the stable contiguous pieces, not the whole
      # line as one string.
      assert html =~
               "curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://emisar.dev/install.sh"

      assert html =~ "sudo EMISAR_ENROLLMENT_KEY="
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
      assert html =~ "customer-authorized MCP bridge"
      refute html =~ "user-signed action"
    end

    # The signed-dispatch operator guide: setup + the fleet key lifecycle
    # (distribute, rotate, revoke) plus the config tokens and a refusal code
    # an operator copies. Stable, apostrophe-free anchors per the describe note.
    test "the signed-dispatch page renders setup, CA distribution, rotation, and revocation",
         %{conn: conn} do
      html = conn |> get(~p"/docs/signed-dispatch") |> html_response(200)

      # The section spine of the how-to.
      assert html =~ "Distributing the CA across a fleet"
      assert html =~ "Rotating operators"
      assert html =~ "Revoking"

      # The exact knobs an operator sets on both ends.
      assert html =~ "emisar signing init"
      assert html =~ "enforce_signatures"
      assert html =~ "trusted_cas"
      assert html =~ "EMISAR_SIGNING_KEY"
      assert html =~ "EMISAR_SIGNING_CERT"
      assert html =~ "max_attestation_age"

      assert html =~
               "A customer-authorized MCP bridge signed the dispatch frame with its locally held Ed25519 key."

      refute html =~ "The MCP client signs"

      # A refusal code from the troubleshooting table.
      assert html =~ "cert_untrusted"
    end

    test "the publishing-packs guide renders the operator commands", %{conn: conn} do
      html = conn |> get(~p"/docs/publishing-packs") |> html_response(200)

      assert html =~ "emisar pack validate"
      assert html =~ "emisar pack install"
      assert html =~ "--hash"

      # Keeping a pack private still scales to a fleet — packctl builds the tree.
      assert html =~ "packctl"

      # install SIGHUP-reloads a running daemon, so the guide drops the redundant manual reload.
      refute html =~ "systemctl reload"
    end

    test "the pack-registry guide renders the packctl flow and the BYO install flags",
         %{conn: conn} do
      html = conn |> get(~p"/docs/pack-registry") |> html_response(200)

      # The full build → host → install path, including the non-GCS route.
      assert html =~ "packctl catalog build"
      assert html =~ "packctl catalog publish"
      assert html =~ "--base-url"
      assert html =~ "--previous"
      assert html =~ "/v1/packs/"
      assert html =~ "--hash sha256:"
      assert html =~ "aws s3 sync"

      # Trust follows the CONFIGURED catalog, and a registry that only moves bytes
      # leaves its packs pending — the page must state both halves.
      assert html =~ "the catalog it is configured to read"
      assert html =~ "arrive pending"
      assert html =~ "EMISAR_PACK_CATALOG_URL"
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
      assert html =~ "execute_runbook"
      assert html =~ "create_runbook_draft"
      assert html =~ "update_runbook_draft"
      assert html =~ "allow_draft: true"
      refute html =~ "test_runbook_draft"
    end

    test "the runbooks walkthrough uses the seeded Caddy procedure and current screenshots", %{
      conn: conn
    } do
      html = conn |> get(~p"/docs/runbooks") |> html_response(200)
      packs_root = Path.expand("../../../../../packs", __DIR__)
      action = File.read!(Path.join(packs_root, "caddy/actions/reload_config.yaml"))

      assert action =~ "id: caddy.reload_config"
      assert html =~ "caddy.reload_config"
      assert html =~ "&quot;pack&quot;: {&quot;id&quot;: &quot;caddy&quot;}"
      assert html =~ "group:edge-web"
      assert html =~ "Every runner in group"
      assert html =~ "One random runner"
      assert html =~ "random_one"
      assert html =~ "does not move the work to another member"
      assert html =~ "one approval for the complete frozen execution"
      assert html =~ "Action arguments"
      assert html =~ "Extracted outputs"
      assert html =~ "Success conditions"
      assert html =~ "Wait policy"
      assert html =~ "caddy.reverse_proxy_upstreams"
      assert html =~ "&quot;expression&quot;: &quot;/healthy&quot;"
      assert html =~ "&quot;operator&quot;: &quot;equals&quot;"
      assert html =~ "&quot;max_attempts&quot;: 12"

      [_, escaped_canonical] =
        Regex.run(~r/Canonical runbook JSON.*?<pre[^>]*>(.*?)<\/pre>/s, html)

      canonical = String.replace(escaped_canonical, "&quot;", "\"")
      assert {:ok, _definition} = Emisar.Runbooks.decode_definition_json(canonical)

      for image <-
            ~w(import inputs stage targets arguments outputs conditions wait start approval result) do
        assert html =~ ~s(src="/images/docs/runbooks/#{image}.webp")
      end

      refute html =~ "/images/screenshots/runbooks.webp"
      refute html =~ "Exact runner"
      refute html =~ "PostgreSQL replication gate"
    end

    test "the MCP reference pins the complete tool and transport contract", %{conn: conn} do
      html = conn |> get(~p"/docs/mcp-reference") |> html_response(200)

      for tool <- ~w(
        list_packs list_runners find_actions get_action run_action get_operation
        wait_for_run recent_runs list_runbooks get_runbook execute_runbook create_runbook_draft
        update_runbook_draft
      ) do
        assert html =~ tool
      end

      assert html =~ "allow_draft: true"
      refute html =~ "test_runbook_draft"

      assert html =~ "60 seconds"
      assert html =~ "eight requests"
      assert html =~ "90-second"
      assert html =~ "notifications/cancelled"
      assert html =~ "2026-07-28"
      assert html =~ "server/discover"
      assert html =~ "2025-11-25"
      assert html =~ "2025-06-18"
      refute html =~ "2024-11-05"
      assert html =~ "does not issue"
      assert html =~ "strings or integers"
      assert html =~ "pack@version/sha256:hash"
      assert html =~ "name~sha256-prefix"
      assert html =~ "signed_runbook_unsupported"
      assert html =~ "A resolved execution may contain 256 items"
      assert html =~ "initial stage state commit"

      # The "Calling the endpoint" on-ramp — the verbatim curl a custom client copies.
      assert html =~ "curl -X POST"
      assert html =~ "https://emisar.dev/api/mcp/rpc"
      assert html =~ "Authorization: Bearer"
      refute html =~ "GET /api/mcp/runners"
    end

    test "the limits and runbooks pages state the shipped output range and runbook schema bounds",
         %{conn: conn} do
      html = conn |> get(~p"/docs/limits") |> html_response(200)

      # The published range is the real spread of per-stream caps across the
      # shipped pack catalog — a pack moving either endpoint must move the docs.
      packs_root = Path.expand("../../../../../packs", __DIR__)
      cap_pattern = ~r/max_std(?:out|err)_bytes(?:_min|_max)?: *(\d+)/

      caps =
        packs_root
        |> Path.join("*/actions/*.yaml")
        |> Path.wildcard()
        |> Enum.map(&File.read!/1)
        |> Enum.flat_map(&Regex.scan(cap_pattern, &1, capture: :all_but_first))
        |> List.flatten()
        |> Enum.map(&String.to_integer/1)

      assert Enum.min(caps) == 64
      assert Enum.max(caps) == 16 * 1024 * 1024
      assert html =~ "64 bytes to 16 MiB"
      assert html =~ "separately for stdout and stderr"
      assert html =~ "each flagged truncated on their own"

      limit = &Emisar.Runbooks.definition_limit!/1
      assert {limit.(:min_wait_interval_seconds), limit.(:max_wait_interval_seconds)} == {5, 3600}
      assert html =~ "every 5 seconds to 1 hour"
      assert {limit.(:min_wait_attempts), limit.(:max_wait_attempts)} == {2, 100}
      assert html =~ "2 to 100 attempts"
      assert limit.(:default_stage_parallelism) == 5
      assert html =~ "5 unless the definition sets it"
      assert limit.(:max_frozen_plan_bytes) == 1024 * 1024
      assert html =~ "1 MiB frozen plan"
      assert limit.(:max_execution_seconds) == 24 * 60 * 60
      assert html =~ "24 hours end to end, waits included"

      # The reference link promises only what that page contains.
      refute html =~ "every method, parameter, error code"
      assert html =~ "recovery semantics"

      runbooks = conn |> get(~p"/docs/runbooks") |> html_response(200)
      assert runbooks =~ "A wait polls every 5 seconds"
      assert runbooks =~ "to 1 hour and makes 2 to 100 attempts"
      assert runbooks =~ "5 unless the definition sets it"
      assert runbooks =~ "frozen execution plan is at most 1 MiB"
      assert runbooks =~ "ends within 24 hours"
    end

    test "the teams-and-access page renders all four roles", %{conn: conn} do
      html = conn |> get(~p"/docs/teams-and-access") |> html_response(200)
      assert html =~ "Owner"
      assert html =~ "Admin"
      assert html =~ "Operator"
      assert html =~ "Viewer"
      # An LLM-access reviewer checks the key model: policy + the minting member's
      # runner scope, not a per-key grant.
      assert html =~ "runner scope"
    end

    test "the authentication hub separates sign-in, enforcement, and lifecycle", %{conn: conn} do
      html = conn |> get(~p"/docs/authentication") |> html_response(200)

      assert html =~ "Magic link"
      assert html =~ "OIDC SSO"
      assert html =~ "Require MFA"
      assert html =~ "Before emisar reveals an authenticator secret"

      assert html =~ "Regenerating recovery codes requires a current authenticator"
      assert html =~ "recovery code; the old set stays valid unless that proof succeeds"

      assert html =~ "provider that supplies no email"
      assert html =~ "Require SSO"
      assert html =~ "SCIM directory sync"
      assert html =~ "Sessions and offboarding"

      for provider <- ["Okta", "Microsoft Entra", "JumpCloud", "Google Workspace", "Keycloak"] do
        assert html =~ provider
      end
    end

    test "the SSO page publishes the generic OIDC and provider lifecycle contracts", %{conn: conn} do
      html = conn |> get(~p"/docs/sso") |> html_response(200)

      assert html =~ "OIDC contract"
      assert html =~ "PKCE"
      assert html =~ "S256 when"
      assert html =~ "openid"
      assert html =~ "email_verified: true"
      assert html =~ "Require SSO for the account"
      assert html =~ "Rotate a client secret"
      assert html =~ "Disable or delete a connection"
      assert html =~ "Troubleshooting"
    end

    test "the SCIM page publishes the wire and directory authorization contracts", %{conn: conn} do
      html = conn |> get(~p"/docs/scim") |> html_response(200)

      assert html =~ "SCIM protocol reference"
      assert html =~ "/ServiceProviderConfig"
      assert html =~ "/Users"
      assert html =~ "/Groups"
      assert html =~ "userName eq"
      assert html =~ "displayName eq"
      assert html =~ "100 PATCH operations"
      assert html =~ "5,000 member ids"
      assert html =~ "Group runner access is"
      assert html =~ "additive"
      assert html =~ "Last sync"
    end

    test "authentication docs expose review dates without a dead edit action", %{conn: conn} do
      for route <- ~w(
            /docs/authentication
            /docs/teams-and-access
            /docs/sso
            /docs/scim
          ) do
        html = conn |> get(route) |> html_response(200)

        assert html =~ "Last reviewed July 31, 2026", "missing review date on #{route}"
        refute html =~ "Suggest a change", "dead edit action returned on #{route}"
        refute html =~ "github.com/andrewdryga/emisar/edit/main/"
      end
    end

    test "each provider guide publishes the evidence its claim rests on", %{conn: conn} do
      evidence = [
        {"/docs/integrations/okta",
         "Verified against a live Okta Integrator org on July 27, 2026."},
        {"/docs/integrations/jumpcloud",
         "Verified against a live JumpCloud tenant on July 31, 2026."},
        {"/docs/integrations/entra", "Guide reviewed July 31, 2026."},
        {"/docs/integrations/google-workspace", "Guide reviewed July 31, 2026."},
        {"/docs/integrations/keycloak", "Guide reviewed July 31, 2026."}
      ]

      for {route, sentence} <- evidence do
        html = conn |> get(route) |> html_response(200)

        assert html =~ sentence, "missing or drifted evidence on #{route}"
        assert html =~ "Last reviewed", "missing review provenance on #{route}"
      end
    end

    test "the runners page renders the host CLI and uninstall flags", %{conn: conn} do
      html = conn |> get(~p"/docs/runners") |> html_response(200)

      # The host-side toolbox + clean removal + the TLS install endpoint.
      assert html =~ "emisar audit verify --all"
      assert html =~ "--uninstall"
      assert html =~ "--purge"
      assert html =~ "current hostname"
      refute html =~ "--reset-identity"
      refute html =~ "/var/lib/emisar/runner_id"
      assert html =~ "https://emisar.dev/install.sh"
    end

    test "the runners page documents both enrollment-key models", %{conn: conn} do
      html = conn |> get(~p"/docs/runners") |> html_response(200)

      # The key-model contract must match the shipped product (EnrollmentKey:
      # single-use default + reusable with max-uses/expiry) — UI-008 regression.
      assert html =~ "Two key models"
      assert html =~ "single-use"
      assert html =~ "reusable"
      assert html =~ "max-uses cap"
      assert html =~ "mint one reusable key"
      refute html =~ "enrolls exactly one runner"
      refute html =~ "Mint per host"
    end

    test "the SSO page's directions match the console's Team-hosted SSO hub", %{conn: conn} do
      html = conn |> get(~p"/docs/sso") |> html_response(200)

      # SSO folded into Team: directions say Team → Single sign-on and the
      # console's own button label (Add provider) — UI-010 regression.
      assert html =~ "Team → Single sign-on"
      assert html =~ "Add provider"
      refute html =~ "Settings → Single sign-on"
      refute html =~ "Add connection</strong>"
    end

    test "the audit-and-siem page renders the SIEM curl and journal verify", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200)

      # The SIEM export contract — endpoint, params, bearer auth, cursor.
      assert html =~ "https://emisar.dev/api/audit"
      assert html =~ "since="
      assert html =~ "limit="
      assert html =~ "Authorization: Bearer"
      assert html =~ "X-Next-Cursor"

      # The retention windows + the journal verify path.
      assert html =~ "/var/log/emisar/events.jsonl"
      assert html =~ "emisar audit verify --all"
    end

    test "the five new operator pages render their key facts", %{conn: conn} do
      runs = conn |> get(~p"/docs/runs") |> html_response(200)
      assert runs =~ "Run statuses"
      assert runs =~ "most recent 500"
      assert runs =~ "SIGTERM"

      keys = conn |> get(~p"/docs/keys") |> html_response(200) |> squish()
      assert keys =~ "emk-"
      assert keys =~ "no scope of its own"
      assert keys =~ "audit-export"
      assert keys =~ "MCP bridge keys are short-lived and rotate themselves"
      assert keys =~ "writable and persistent"

      assert keys =~
               "OAuth tokens, arbitrary Bearer tokens, non-expiring quick-connect keys, and audit-export tokens bypass local rotation state."

      cli = conn |> get(~p"/docs/runner-cli") |> html_response(200)
      assert cli =~ "emisar audit verify --all"
      assert cli =~ "/etc/emisar/config.yaml"
      assert cli =~ "sudo emisar update"
      assert cli =~ "requires the root-owned receipt"

      billing = conn |> get(~p"/docs/billing") |> html_response(200)
      assert billing =~ "7 days on Free, 90 on Team, 365 on Enterprise"
      assert billing =~ "Paddle"
    end

    test "the CSI data-loss use case renders its incident narrative and CTAs", %{conn: conn} do
      html = conn |> get(~p"/use-cases/csi-data-loss") |> html_response(200)

      assert html =~ "Case study · Storage"
      assert html =~ "Stop the bleed"
      assert html =~ ~s(href="/sign_up")
      assert html =~ ~s(href="/docs/security-model")
      assert html =~ ~s(href="/docs/action-packs")
    end

    test "the Cassandra migration use case renders the migration, tools, proof, and CTAs",
         %{conn: conn} do
      html = conn |> get(~p"/use-cases/cassandra-migration") |> html_response(200)

      assert html =~ "Case study · Database migration"
      assert html =~ "How I helped move Cassandra from GCP to bare metal"
      assert html =~ "Moving Cassandra from GCP to bare metal: an AI operator"
      assert html =~ "Written by ChatGPT Sol"
      assert html =~ "Human review by the operator."
      assert html =~ "emisar connected the plan to the live systems"
      assert html =~ "The same four-tool loop worked across the migration"
      assert html =~ "Stage 0"
      assert html =~ "Plan the migration"
      assert html =~ "High-level plan"
      assert html =~ "Stage 1"
      assert html =~ "Learn what production really needed"
      assert html =~ "Stage 2"
      assert html =~ "I authored the destination"
      assert html =~ "Stage 3"
      assert html =~ "Then I operated it in isolation"
      assert html =~ "Stage 4"
      assert html =~ "Stress, tune, and prove the destination"
      refute html =~ "Blitz ran"
      assert html =~ "the vendor accepted the"
      assert html =~ "15,700 lines"
      assert html =~ "37.8 million operations"
      assert html =~ "8.23 ms"
      assert html =~ "4.32 ms"
      assert html =~ "Logical dataset"
      assert html =~ "≈6.3 TiB"
      assert html =~ "Cutover hour"
      assert html =~ "0 errors"
      assert html =~ "The gate to join production"
      assert html =~ "GCP kept serving every application while VA1 joined"
      assert html =~ "Stage 5"
      refute html =~ "Phase 5"
      assert html =~ "Join, stream, cut over, and retire GCP"
      assert html =~ "gcp.interconnect_utilization"
      assert html =~ "The tools that mattered most"
      assert html =~ "made this broad toolset feel like one reliable system"
      assert html =~ "<code>cassandra.nodetool_status</code>"
      assert html =~ "<code>cassandra.nodetool_decommission</code>"
      assert html =~ "<code>cassandra.nodetool_setinterdcstreamthroughput</code>"
      assert html =~ "tfc.plan_summary"
      assert html =~ "tfc.run_diagnostics"
      assert html =~ "gh.workflow_run_view"
      assert html =~ "<code>pure.arrays_performance</code>"
      assert html =~ "<code>pure.network_interfaces_performance</code>"
      assert html =~ "stream_entire_sstables=false"
      assert html =~ "Storage-Attached Index"
      assert html =~ "Risky work still belonged to a person"
      assert html =~ "Human feedback changed the plan"
      assert html =~ "Do not overcorrect"
      refute html =~ "YOU DO NOT TOUCH GCP RIGHT NOW"
      refute html =~ "Tarkov"
      refute html =~ "valorant_ks"
      refute html =~ "14.28 TiB"
      refute html =~ "755 GiB"
      refute html =~ "15 TiB"
      assert html =~ "What emisar did not replace"
      assert html =~ ~s(href="/sign_up")
      assert html =~ ~s(href="/packs/cassandra")
      assert html =~ ~s(href="/docs/security-model")
      refute html =~ ~s(href="/docs/audit-and-siem")
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

    test "the copy-paste comparison renders the manual workflow, honest tradeoffs, and both table layouts",
         %{conn: conn} do
      html = conn |> get(~p"/compare/copy-paste-ai-ops") |> html_response(200)

      assert html =~ "The copy-paste loop"
      assert html =~ "Nothing runs unless you run it. That matters."
      assert html =~ "Review can turn into a reflex"
      assert html =~ "That is the worst of both worlds"
      assert html =~ "Nothing on its own. You run every command."
      assert html =~ "Copy-paste may be enough"
      assert html =~ "When the command comes back, make it an action"
      assert html =~ "/images/screenshots/audit-successes.webp"
      assert html =~ "<table"
    end

    test "the sitemap lists the copy-paste workflow comparison", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)
      assert body =~ "https://emisar.dev/compare/copy-paste-ai-ops</loc>"
    end
  end

  describe "day-two operations pages" do
    # These four pages are procedures an operator runs against production, so
    # what's pinned here is the part that would be dangerous if it silently
    # changed: the commands, the limits stated beside them, and the
    # ownership boundaries between the four lifecycles. Not paragraphs.

    test "upgrades derives its compatibility thresholds instead of hard-coding a snapshot",
         %{conn: conn} do
      html = conn |> get(~p"/docs/upgrades") |> html_response(200)

      # The page interpolates the requirement strings, so the rendered form is
      # escaped (">= 0.10.0" arrives as "&gt;= 0.10.0").
      for requirement <- [Emisar.Compat.runner_minimum(), Emisar.Compat.mcp_minimum()] do
        assert html =~ Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(requirement))
      end
    end

    test "upgrades states the verified version commands and the interruption they cause",
         %{conn: conn} do
      html = conn |> get(~p"/docs/upgrades") |> html_response(200)

      assert html =~ "emisar --version"
      assert html =~ "emisar-mcp --version"
      assert html =~ "emisar doctor"
      assert html =~ "sudo emisar update --version &lt;target-version&gt;"
      assert html =~ "install.sh"
      assert html =~ "install-mcp.sh"

      # A binary upgrade stops the service, so the page must not read as
      # zero-downtime — and rollback restores the runner, not the filesystem.
      assert html =~ "The service does stop"
      assert html =~ "restores the previous binary"
      refute html =~ "no interruption"
    end

    test "upgrades pins a placeholder release, never an example tag that ages", %{conn: conn} do
      html = conn |> get(~p"/docs/upgrades") |> html_response(200)

      assert html =~ "--version &lt;target-version&gt;"
      assert html =~ "--version &lt;known-good-version&gt;"

      # A literal tag in a runnable installer line ages into advice to install
      # an old release; the thresholds beside it stay derived from Emisar.Compat.
      refute html =~ "--version 0."
    end

    test "upgrades keeps packs, bridges, and downgrades honestly bounded", %{conn: conn} do
      html = conn |> get(~p"/docs/upgrades") |> html_response(200)

      assert html =~ "A running client keeps the binary it already loaded"
      assert html =~ "Client config and API key are untouched"
      assert html =~ "not a downgrade guarantee"
      assert html =~ "Packs do not move with the binary"
      assert html =~ "infrastructure-managed runner is refused"
    end

    test "credentials opens with a matrix carrying every field the reader compares on",
         %{conn: conn} do
      html = conn |> get(~p"/docs/credentials") |> html_response(200)

      columns = [
        "Credential",
        "Where it is used and stored",
        "Authority",
        "Routine rotation",
        "Immediate containment",
        "Overlap",
        "Effect on sessions and runners",
        "Owner page"
      ]

      for column <- columns do
        assert html =~ ~r{<th[^>]*>#{column}</th>},
               "the credentials matrix is missing the #{column} column"
      end

      # Every row hands the reader off to a real docs page.
      for owner <- ~w(/docs/keys /docs/audit-and-siem /docs/runners /docs/sso /docs/scim
                      /docs/signed-dispatch) do
        assert html =~ ~s(href="#{owner}")
      end
    end

    test "credentials cuts the audit poller over on its own persisted cursor", %{conn: conn} do
      html = conn |> get(~p"/docs/credentials") |> html_response(200)

      assert html =~ "own state, not the token"
      assert html =~ "resumes from exactly the cursor"

      # One clean poll proves the credential and the write path, not that a
      # re-read or a gap has become impossible.
      assert html =~ "guarantee of exactly-once delivery"
    end

    test "credentials separates the two emk- kinds and their revocation reach", %{conn: conn} do
      html = conn |> get(~p"/docs/credentials") |> html_response(200)

      assert html =~ "emk-"
      assert html =~ "wrong kind"
      assert html =~ "Revocation is terminal and it cascades"
      assert html =~ "OAuth-backed keys do not rotate"
    end

    test "credentials keeps enrollment keys, runner tokens, and SCIM distinct", %{conn: conn} do
      html = conn |> get(~p"/docs/credentials") |> html_response(200)

      assert html =~ "Revocation blocks registrations, not connections"
      assert html =~ "Disable is reversible"
      assert html =~ "Delete is terminal"
      assert html =~ "immediately with no overlap"
      assert html =~ "does not sign anyone out"
    end

    test "credentials states the runner token's self-rotation and its one prerequisite",
         %{conn: conn} do
      html = conn |> get(~p"/docs/credentials") |> html_response(200) |> squish()

      # The schedule, sourced from @token_lifetime_seconds / @token_refresh_after_seconds /
      # @token_retirement_grace_seconds in Emisar.Runners — change those and this fails.
      assert html =~ "A per-runner token rotates itself"
      assert html =~ "90-day life, and at 60 days the runner exchanges it for a successor"
      assert html =~ "keeps working for 24 hours after that swap"

      # Never claim it unconditionally: a pre-rotation token has no expiry by
      # design, and saying otherwise would promise expiry we do not enforce.
      assert html =~ "needs a runner on 0.17.0 or newer"
      assert html =~ "Nothing expires a runner that has no way to renew itself"

      # The comparison table agreed the token never rotated and had no overlap.
      # Both were wrong once enforcement landed.
      assert html =~ "Automatic — the runner swaps itself onto a successor at 60 days"
      assert html =~ "the outgoing token works for 24 hours after the swap"
      refute html =~ "None — the new token replaces the cached one"
    end

    test "credentials keeps the no-leaf-revocation limit visible", %{conn: conn} do
      html = conn |> get(~p"/docs/credentials") |> html_response(200)

      assert html =~ "no per-certificate kill switch"
      assert html =~ "Every runner reloaded"
    end

    test "pack updates states the install-versus-trust boundary and its invariants",
         %{conn: conn} do
      html = conn |> get(~p"/docs/pack-updates") |> html_response(200)

      assert html =~ "Installing is not trusting"
      assert html =~ "Trust binds one exact content hash"
      assert html =~ "A published version is immutable"
      assert html =~ "Binary upgrades do not move packs"
      assert html =~ "Retirement blocks dispatch, not installation"
    end

    test "pack updates uses real runner commands and claims no universal rollback",
         %{conn: conn} do
      html = conn |> get(~p"/docs/pack-updates") |> html_response(200)

      assert html =~ "emisar pack update --dry-run"
      assert html =~ "emisar pack install redis=0.2.3 --hash"
      assert html =~ "There is no rollback command"
      assert html =~ "crash-atomic"
      assert html =~ "Several packs update independently"
    end

    test "network requirements names the real runner endpoints and no inbound listener",
         %{conn: conn} do
      html = conn |> get(~p"/docs/network-requirements") |> html_response(200)

      assert html =~ "/runner/register"
      assert html =~ "/runner/socket/websocket"
      assert html =~ "/api/mcp/rpc"
      assert html =~ "registry.emisar.dev"
      assert html =~ "api.github.com"
      assert html =~ "needs no open port"

      assert html =~
               "The runner opens an outbound TLS WebSocket and exposes no inbound listener; commands return through that established connection."
    end

    test "network requirements claims only the transport behavior the clients implement",
         %{conn: conn} do
      html = conn |> get(~p"/docs/network-requirements") |> html_response(200)

      assert html =~ "HTTPS_PROXY"
      assert html =~ "TLS 1.2 or newer"
      assert html =~ "Redirects are refused"

      # No SSE/WebSocket/session on the bridge, and the page says outright
      # that emisar owns no trust-store, pinning, or client-certificate knob.
      assert html =~ "no session for a network appliance"
      assert html =~ "certificate pinning, or client-certificate configuration"
      refute html =~ "mutual TLS"
    end

    test "network requirements opens with a table carrying the rule an operator writes",
         %{conn: conn} do
      html = conn |> get(~p"/docs/network-requirements") |> html_response(200)

      columns = [
        "Operation and component",
        "Direction",
        "Destination and port",
        "Protocol",
        "Why",
        "When required"
      ]

      for column <- columns do
        assert html =~ ~r{<th[^>]*>#{column}</th>},
               "the network table is missing the #{column} column"
      end

      assert html =~ "TCP 443"
      assert html =~ "Only while install.sh or install-mcp.sh runs"
    end

    test "network requirements ends with completion conditions, not a made-up probe",
         %{conn: conn} do
      html = conn |> get(~p"/docs/network-requirements") |> html_response(200)

      assert html =~ ~s(id="verify")
      assert html =~ "no emisar command that tests your firewall"

      assert html =~ "sudo emisar doctor"
      assert html =~ "emisar-mcp --version"
      assert html =~ "one discovery call from the LLM client"
    end

    test "the wide day-two tables scroll sideways instead of clipping", %{conn: conn} do
      # Eight columns cannot fit the docs measure, so the wrapper must scroll
      # and the table must keep a readable minimum width.
      for {path, min_width} <- [
            {~p"/docs/credentials", "1280px"},
            {~p"/docs/network-requirements", "1120px"},
            {~p"/docs/upgrades", "680px"}
          ] do
        html = conn |> get(path) |> html_response(200)

        assert html =~
                 ~r{overflow-x-auto rounded-xl border border-zinc-800">\s*<table class="w-full min-w-\[#{min_width}\]},
               "#{path} clips its table instead of scrolling it"
      end
    end
  end

  describe "recovery and reference pages" do
    # Troubleshooting routes, Security incidents contains, Architecture
    # explains. What's pinned is the part a reader would act on and we would
    # regret getting wrong: the lifecycle distinctions, the revocation reach,
    # and the failure semantics — never paragraphs.

    test "troubleshooting covers every symptom and sends each to its owner", %{conn: conn} do
      html = conn |> get(~p"/docs/troubleshooting") |> html_response(200) |> squish()

      for anchor <- ~w(never-appears offline crash-loop packs dispatch runs mcp identity audit) do
        assert html =~ ~s(id="#{anchor}"), "troubleshooting is missing the ##{anchor} symptom"
      end

      # Each symptom hands off rather than restating the reference.
      for owner <- ~w(/docs/runners /docs/host-install /docs/pack-updates /docs/action-packs
                      /docs/runs /docs/mcp-reference /docs/keys /docs/audit-and-siem
                      /docs/network-requirements /docs/policies-and-approvals) do
        assert html =~ ~s(href="#{owner}"), "troubleshooting never links #{owner}"
      end
    end

    test "troubleshooting keeps the runner and run lifecycles distinct", %{conn: conn} do
      html = conn |> get(~p"/docs/troubleshooting") |> html_response(200) |> squish()

      # Disable is recoverable without host access; delete is terminal.
      assert html =~ "keeps retrying with its existing token"
      assert html =~ "A deleted runner is terminal"

      # A queued run is waiting, not lost; an interrupted one is never rerun
      # behind the operator's back.
      assert html =~ "delivered as soon as that runner reconnects"
      assert html =~ "execution_outcome_unknown"
      assert html =~ "never re-runs that dispatch automatically"
    end

    test "troubleshooting recovers a lost MCP response by operation, never by repeating it",
         %{conn: conn} do
      html = conn |> get(~p"/docs/troubleshooting") |> html_response(200) |> squish()

      assert html =~ "get_operation"
      assert html =~ "same credential lineage"
      assert html =~ "does not roll back work the control plane already admitted"
      assert html =~ "target_contract_changed"
    end

    test "troubleshooting names the evidence, the redaction rule, and both escalation paths",
         %{conn: conn} do
      html = conn |> get(~p"/docs/troubleshooting") |> html_response(200) |> squish()

      for evidence <- [
            "emisar --version",
            "emisar-mcp --version",
            "The UTC time window",
            "runner name and group",
            "The identifiers",
            "sudo emisar doctor",
            "journalctl -u emisar -n 200",
            "emisar events tail --lines 100",
            "The exact error text"
          ] do
        assert html =~ evidence, "the evidence checklist is missing #{evidence}"
      end

      assert html =~ "Redact before you send"
      assert html =~ "Never paste a raw token"
      assert html =~ ~s(href="/support")
      assert html =~ "security@emisar.dev"
      assert html =~ ~s(href="/docs/security-incidents")
    end

    test "security incidents leads with one sequence and a playbook per credential",
         %{conn: conn} do
      html = conn |> get(~p"/docs/security-incidents") |> html_response(200) |> squish()

      for step <- [
            "Contain.",
            "Preserve the evidence.",
            "Rotate or revoke the rest.",
            "Restore a known-good path.",
            "Verify both directions.",
            "Review the audit trail."
          ] do
        assert html =~ step, "the containment sequence is missing #{step}"
      end

      for anchor <- ~w(evidence mcp-key audit-token enrollment-key runner-host pack
                       signing-leaf signing-ca idp) do
        assert html =~ ~s(id="#{anchor}"), "security incidents is missing the ##{anchor} playbook"
      end
    end

    test "security incidents states how far each revocation actually reaches", %{conn: conn} do
      html = conn |> get(~p"/docs/security-incidents") |> html_response(200) |> squish()

      # An MCP key is revoked, not rotated — and revocation takes the chain and
      # the OAuth credentials backed by it.
      assert html =~ "Revoke it — do not rotate it"
      assert html =~ "every successor in that key's rotation chain"
      assert html =~ "OAuth access and refresh token backed by it"

      # An enrollment key does not hold the fleet online.
      assert html =~ "It blocks new registrations"
      assert html =~ "connected on its own token"

      # A possibly-copied runner token is replaced, never paused and resumed.
      assert html =~ "disabling an identity keeps its token"
      assert html =~ "Delete the runner identity"

      # An audit-export token cannot execute anything.
      assert html =~ "separate credential kind from an MCP key"
    end

    test "security incidents preserves immutable evidence before it cleans up", %{conn: conn} do
      html = conn |> get(~p"/docs/security-incidents") |> html_response(200) |> squish()

      assert html =~ "sudo emisar audit verify --all"
      assert html =~ "exact pack hashes"
      assert html =~ "deletes the journal"
      assert html =~ "do not erase an immutable published artifact"
      assert html =~ "never send its value"
    end

    test "security incidents keeps the signing and identity limits visible", %{conn: conn} do
      html = conn |> get(~p"/docs/security-incidents") |> html_response(200) |> squish()

      # No per-leaf CRL: short TTLs bound it, CA rotation is the only lever.
      assert html =~ "no per-certificate revocation list"
      assert html =~ "Remove the old CA and reload every runner"
      assert html =~ "still accepts certificates signed by it"

      # Replacing an OIDC secret is not a session revocation; SCIM has no overlap.
      assert html =~ "does not sign anybody out"
      assert html =~ "leaves API keys and OAuth credentials untouched"
      assert html =~ "Rotating replaces it immediately, with no overlap"
    end

    test "architecture states each failure case the way the system behaves", %{conn: conn} do
      html = conn |> get(~p"/docs/architecture") |> html_response(200) |> squish()

      assert html =~ "there is no offline dispatch path"
      assert html =~ "An action already executing on a runner keeps running"
      assert html =~ "The runner process is still alive, so the child process keeps running"
      assert html =~ "may still be winding down, or may have been terminated"
      assert html =~ "execution_outcome_unknown after restart"
      assert html =~ "never executes that dispatch again automatically"
      assert html =~ "already admitted keeps going"
      assert html =~ "exact pack references frozen at preflight"
      assert html =~ "warned about rather than refused"
    end

    test "architecture claims at-least-once delivery, never exactly-once execution",
         %{conn: conn} do
      html = conn |> get(~p"/docs/architecture") |> html_response(200) |> squish()

      assert html =~ "delivered at least once"
      assert html =~ "consumes them idempotently"
      assert html =~ "not a promise that an action executes exactly once"
    end

    test "architecture lists only the approval rechecks the code performs", %{conn: conn} do
      html = conn |> get(~p"/docs/architecture") |> html_response(200) |> squish()

      assert html =~ "still parked and still approvable"
      assert html =~ "still matches the hash frozen"
      assert html =~ "still has that runner in scope"
      assert html =~ "inside its freshness window"

      # The approver's decision is not re-litigated; only its preconditions.
      assert html =~ "not a second policy evaluation"
    end

    test "architecture owns topology and hands threats to the security model", %{conn: conn} do
      html = conn |> get(~p"/docs/architecture") |> html_response(200) |> squish()

      assert html =~ "There is no listener on the runner host"
      assert html =~ "nothing for you to upgrade there"
      assert html =~ ~s(href="/docs/security-model")

      # Ownership and state are tables, not a decorative diagram.
      assert html =~ ~s(id="ownership")
      assert html =~ ~s(id="state")
    end
  end

  describe "the audit export contract across public surfaces" do
    # The export is a PULL API — cursor-paginated NDJSON read with an
    # :audit_export bearer. Copy that implies emisar pushes ("real-time
    # streaming to SIEM") sends operators looking for a log sink that does not
    # exist, so the contract facts and the absence of push claims are both
    # pinned here rather than left to a reviewer's memory.

    test "audit & SIEM states the whole contract in one place", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200) |> squish()

      assert html =~ "GET /api/audit"
      assert html =~ "audit-export"
      assert html =~ "X-Next-Cursor"
      assert html =~ ~s(rel="next")
      assert html =~ "60 requests a minute"

      # The two headers mean different things, and neither rides an empty page.
      assert html =~ "An empty page is an answer."
      assert html =~ "it is not a promise that another event"

      # A cursor is a position, not a scoped handle — so the filters are the
      # caller's responsibility for the life of the chain.
      assert html =~ "Keep the filters identical for the life of a cursor."
      assert html =~ "For roles with full audit access, the record is account-wide"
      assert html =~ "Billing managers see only billing events"
    end

    test "audit & SIEM says plainly that emisar does not push", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200)

      assert html =~ "emisar does not push events."
      assert html =~ "There is no managed log sink, webhook, or streaming transport."

      # Direct-polling SIEM vs. a collector in front of one — the distinction
      # that decides whether an operator has anything to run at all.
      assert html =~ "otherwise a collector polls emisar and forwards"
      assert html =~ "Collector is a role, not another service you have to run"
    end

    test "audit & SIEM ships a poller that checkpoints after handoff", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200)

      assert html =~ ~s(id="polling")

      # Bootstrap once, resume from the persisted cursor after that.
      assert html =~ "used only when there is no cursor yet"
      assert html =~ "identical for the life of this cursor"

      # A failed request must not read as an empty page, and the cursor must
      # not move when one happens.
      assert html =~ "curl -fsS"
      assert html =~ "does not move on failure"

      # Hand off, then persist; empty means caught up; Link means keep paging.
      assert html =~ "x-next-cursor"
      assert html =~ "Hand off first, persist second"
      assert html =~ ~s(if ! <span class="text-brand-300">"$SINK"</span> &lt;)
      assert html =~ "exits nonzero on rejection; that leaves the cursor unchanged for retry"

      {sink_position, _} = :binary.match(html, ~s(if ! <span class="text-brand-300">"$SINK"))

      {checkpoint_position, _} =
        :binary.match(html, ~s(cursor=<span class="text-brand-300">"$next"))

      assert sink_position < checkpoint_position

      assert html =~ "awk exits successfully"
      assert html =~ "caught up, keep the cursor"
      assert html =~ "keep paging while it does"

      # The token is environment, the cursor is state — which is what makes a
      # credential swap not a re-read of history.
      assert html =~ "The token lives in the environment"
      assert html =~ ~s(href="/docs/credentials#audit-tokens")
    end

    test "audit & SIEM explains its own exports without calling them activity", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200)

      assert html =~ ~s(id="health")
      assert html =~ "audit.exported"
      assert html =~ "as operator activity"

      # Each read can create the event the next read finds, so "drain until
      # empty" is a loop that feeds itself.
      assert html =~ "never poll until a page comes back empty"
    end

    test "audit & SIEM owns alerting, retention, and journal correlation", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200)

      for anchor <- ~w(alerting retention journal) do
        assert html =~ ~s(id="#{anchor}"), "audit & SIEM lost its #{anchor} section"
      end

      assert html =~ "policy.updated"
      assert html =~ "action_blocked_by_admission"
      assert html =~ "7 days on Free, 90 on Team, 365 on Enterprise"

      # The two records are evidence together; a mismatch starts an
      # investigation, while the poll interval alone is not a gap.
      assert html =~ "A mismatch is an investigation signal"
      assert html =~ "first allow for the collector's poll interval"
    end

    test "no public page claims emisar streams or pushes the audit anywhere", %{conn: conn} do
      push_claims = [
        ~r/real[-\s]time streaming/i,
        ~r/streaming NDJSON/i,
        ~r/stream(s|ing|ed)? (it |them |the )?(audit )?to (your |a )?SIEM/i,
        ~r/streamable to your SIEM/i
      ]

      surfaces = ~w(
        /docs/audit-and-siem /docs/deployment /docs/billing /docs/limits /docs/runs
        /docs/security-model /docs/keys /docs/runner-cli /docs/troubleshooting
        /docs/credentials /how-it-works /zero-trust /security /trust / /privacy /dpa
        /compare/copy-paste-ai-ops /compare/custom-mcp-server
      )

      for path <- surfaces, claim <- push_claims do
        html = conn |> get(path) |> html_response(200)

        refute html =~ claim,
               "#{path} still claims emisar pushes the audit trail (#{inspect(claim)})"
      end
    end

    test "the audit-and-siem page metadata describes the pull API it documents", %{conn: conn} do
      html = conn |> get(~p"/docs/audit-and-siem") |> html_response(200)

      assert html =~ "polling the NDJSON export API"
      assert html =~ "read-only audit-export token"

      # The credential kind never had a `audit:read` scope name.
      refute html =~ "audit:read"
    end
  end

  describe "owner pages route to the day-two pages that own the procedure" do
    # Each of these pages keeps its reference detail and hands off the
    # procedure. A missing link is how a reader ends up reinventing a rollout,
    # a rotation, or an incident response from a reference table.

    @owner_links [
      {"/docs/runners",
       ~w(/docs/upgrades /docs/pack-updates /docs/troubleshooting /docs/security-incidents)},
      {"/docs/runner-cli", ~w(/docs/upgrades /docs/troubleshooting)},
      {"/docs/authentication",
       ~w(/docs/credentials /docs/security-incidents /docs/troubleshooting)},
      {"/docs/sso", ~w(/docs/credentials /docs/security-incidents /docs/troubleshooting)},
      {"/docs/scim", ~w(/docs/credentials /docs/security-incidents /docs/troubleshooting)},
      {"/docs/mcp-reference", ~w(/docs/troubleshooting)},
      {"/support", ~w(/docs/troubleshooting /docs/security-incidents)},
      {"/docs/deployment", ~w(/docs/upgrades /docs/pack-updates /docs/audit-and-siem)},
      {"/docs/security-model",
       ~w(/docs/architecture /docs/security-incidents /docs/audit-and-siem)},
      {"/docs/audit-and-siem", ~w(/docs/credentials /docs/policies-and-approvals)}
    ]

    for {path, owners} <- @owner_links do
      test "#{path} links the pages that own what it defers", %{conn: conn} do
        html = conn |> get(unquote(path)) |> html_response(200)

        for owner <- unquote(owners) do
          assert html =~ ~r/href="#{owner}(#[a-z-]+)?"/,
                 "#{unquote(path)} no longer routes to #{owner}"
        end
      end
    end

    test "every operational limit names the page that owns its behavior", %{conn: conn} do
      html = conn |> get(~p"/docs/limits") |> html_response(200)

      for owner <- ~w(/docs/action-packs /docs/runs /docs/mcp-reference /docs/runbooks
                      /docs/audit-and-siem) do
        assert html =~ ~r/href="#{owner}(#[a-z-]+)?"/,
               "the limits table stopped linking #{owner}"
      end

      # The rate limit is a cap operators hit before any other one, and its
      # observable consequence is a status code, not a slower page.
      assert html =~ "60 requests a minute per token"
      assert html =~ "429"
    end

    test "the changelog stays the release notes the upgrade page points at", %{conn: conn} do
      html = conn |> get(~p"/docs/upgrades") |> html_response(200)

      assert html =~ ~s(href="/changelog")
    end
  end

  describe "Require SSO states its boundary" do
    # Require SSO is a browser sign-in control. Reading it as an account-wide
    # kill switch is the dangerous misunderstanding: an operator who believes
    # it revoked API credentials will not go and revoke them.

    test "authentication scopes Require SSO to browser sign-in, with no bypass", %{conn: conn} do
      html = conn |> get(~p"/docs/authentication") |> html_response(200)

      assert html =~ "with no bypass"
      assert html =~ "It does not authenticate an MCP bearer"
      assert html =~ "Turning it on revokes no existing API key"
      assert html =~ "applies only while at least one"

      # Not a fail-open: an enabled-but-broken provider keeps the gate shut.
      assert html =~ "does not open the gate"
    end

    test "sso repeats only the boundary, and points at the owner", %{conn: conn} do
      html = conn |> get(~p"/docs/sso") |> html_response(200)

      assert html =~ "It gates account browser access and new OAuth consent"
      assert html =~ ~s(href="/docs/authentication#enforcement")
    end
  end

  describe "plan notes on plan-gated docs (the upsell markers)" do
    test "docs/sso marks SSO login as Team+, linking to pricing", %{conn: conn} do
      html = conn |> get(~p"/docs/sso") |> html_response(200)

      # The plan-gated feature ends its paragraph with an "Only available on
      # <tier>" note naming the tier(s) that have it…
      assert html =~ "Only available on"
      assert html =~ "Team &amp; Enterprise"
      assert html =~ "Available on the Team and Enterprise plans"
      # …and the tier name is the upsell — it links to pricing.
      assert html =~ ~s(href="/pricing")
    end

    test "docs/scim marks directory sync as Enterprise, linking to pricing", %{conn: conn} do
      html = conn |> get(~p"/docs/scim") |> html_response(200)

      assert html =~ "Only available on"
      assert html =~ "Available on the Enterprise plan"
      assert html =~ ~s(href="/pricing")
    end

    test "the docs index and sidebar carry no plan tags — the gate lives on the page",
         %{conn: conn} do
      # Founder call (2026-07-18): nav surfaces are wayfinding; a verbatim
      # plan label there wraps into noise. The SSO page itself (asserted
      # above) is where the paywall is named.
      html = conn |> get(~p"/docs") |> html_response(200)

      refute html =~ "Team &amp; Enterprise"
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
      "/docs/publishing-packs" => ~w(/packs /docs/action-packs /docs/pack-registry),
      "/docs/pack-registry" => ~w(/docs/publishing-packs /docs/action-packs /packs),
      "/docs/policies-and-approvals" =>
        ~w(/docs/runbooks /docs/audit-and-siem /docs/security-model),
      "/docs/runbooks" =>
        ~w(/docs/policies-and-approvals /docs/connect-an-llm /docs/action-packs),
      "/docs/authentication" => ~w(/docs/teams-and-access /docs/sso /docs/scim),
      "/docs/upgrades" =>
        ~w(/changelog /docs/pack-updates /docs/keys /docs/deployment /docs/runners),
      "/docs/credentials" =>
        ~w(/docs/keys /docs/audit-and-siem /docs/runners /docs/sso /docs/scim /docs/signed-dispatch),
      "/docs/pack-updates" =>
        ~w(/docs/upgrades /docs/action-packs /docs/publishing-packs /docs/pack-registry /packs),
      "/docs/network-requirements" =>
        ~w(/docs/host-install /docs/upgrades /docs/pack-registry /docs/containers /docs/kubernetes /docs/nomad /docs/runners),
      "/docs/troubleshooting" =>
        ~w(/docs/runners /docs/host-install /docs/pack-updates /docs/action-packs /docs/runs
           /docs/mcp-reference /docs/keys /docs/credentials /docs/upgrades /docs/audit-and-siem
           /docs/network-requirements /docs/policies-and-approvals /docs/teams-and-access
           /docs/signed-dispatch /docs/security-incidents /support),
      "/docs/security-incidents" =>
        ~w(/docs/credentials /docs/audit-and-siem /docs/pack-updates /docs/pack-registry
           /docs/signed-dispatch /docs/sso /docs/scim /docs/authentication /docs/troubleshooting
           /support),
      "/docs/architecture" =>
        ~w(/docs/security-model /docs/network-requirements /docs/upgrades /docs/runs
           /docs/troubleshooting /docs/policies-and-approvals /docs/signed-dispatch /how-it-works
           /changelog),
      "/docs/teams-and-access" =>
        ~w(/docs/sso /docs/connect-an-llm /docs/policies-and-approvals /docs/audit-and-siem),
      "/use-cases/cassandra-migration" => ~w(/packs/cassandra /docs/security-model),
      "/use-cases/ingress-502" =>
        ~w(/use-cases/csi-data-loss /docs/security-model /docs/action-packs),
      "/compare/raw-ssh-for-ai" => ~w(/docs/quickstart /pricing),
      "/compare/custom-mcp-server" =>
        ~w(/docs/security-model /docs/action-packs /compare/raw-ssh-for-ai),
      "/compare/copy-paste-ai-ops" =>
        ~w(/docs/connect-an-llm /docs/audit-and-siem /docs/security-model /docs/action-packs /compare/raw-ssh-for-ai)
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
      for route <- ~w(/privacy /terms /refund-policy /dpa) do
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
            {"/privacy", "July 12, 2026"},
            {"/terms", "June 4, 2026"},
            {"/refund-policy", "June 5, 2026"},
            {"/dpa", "July 18, 2026"}
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
      dpa = conn |> get(~p"/dpa") |> html_response(200)

      # Privacy: support (data requests) + security (disclosure).
      assert privacy =~ "mailto:support@emisar.dev"
      assert privacy =~ "mailto:security@emisar.dev"
      # Terms + Refund: support (general) + sales (enterprise).
      assert terms =~ "mailto:support@emisar.dev"
      assert terms =~ "mailto:sales@emisar.dev"
      assert refund =~ "mailto:support@emisar.dev"
      assert refund =~ "mailto:sales@emisar.dev"
      assert dpa =~ "mailto:support@emisar.dev"
    end

    test "the DPA separates minimum measures from customer-controlled runner controls", %{
      conn: conn
    } do
      html = conn |> get(~p"/dpa") |> html_response(200)
      text = Regex.replace(~r/\s+/, html, " ")

      assert text =~ "These controls are not enabled or configured by default"
      assert text =~ "When you enable signed dispatch"
      assert text =~ "When you configure local admission rules"
      assert text =~ "You are responsible for enabling and configuring these controls"

      assert text =~
               "Runner output is redacted before leaving the host; Emisar retains the resulting redacted output in audit log."

      assert text =~ "privileged host operator"
      assert text =~ "replace or truncate the entire local journal"

      refute text =~
               "Signed dispatch and local admission control — a compromised control plane cannot forge an action"
    end

    test "the privacy, trust, and DPA pages name only the real subprocessors", %{conn: conn} do
      for route <- ~w(/privacy /trust /dpa) do
        html = conn |> get(route) |> html_response(200)

        assert html =~ "Paddle", "missing Paddle disclosure on #{route}"
        assert html =~ "Postmark", "missing Postmark disclosure on #{route}"
        assert html =~ "Google Cloud Platform", "missing GCP disclosure on #{route}"
        assert html =~ "Mixpanel", "missing Mixpanel disclosure on #{route}"
        assert html =~ "Sentry", "missing Sentry disclosure on #{route}"
        assert html =~ "Paddle Retain", "missing Paddle Retain disclosure on #{route}"
      end

      privacy = conn |> get(~p"/privacy") |> html_response(200)
      assert privacy =~ "checkout page only"
    end

    test "the Sentry before_send scrubber drops PII and redacts secrets" do
      event = %Sentry.Event{
        event_id: String.duplicate("a", 32),
        timestamp: "2026-07-16T00:00:00",
        request: %Sentry.Interfaces.Request{
          url: "https://emisar.dev/app?email=person@example.com",
          query_string: %{"email" => "person@example.com", "token" => "query-secret"},
          data: %{"password" => "body-secret"},
          cookies: %{"session" => "session-secret"},
          headers: %{"authorization" => "bearer-secret"},
          env: %{"secret" => "env-secret"}
        },
        user: %{id: "user-id", email: "person@example.com", ip_address: "203.0.113.10"},
        extra: %{
          "api_key" => "api-secret",
          "nested" => %{"password" => "password-secret", "safe" => "kept"}
        }
      }

      scrubbed = EmisarWeb.Application.scrub_sentry_event(event)

      assert scrubbed.request.url == "https://emisar.dev/app"
      assert scrubbed.request.query_string == nil
      assert scrubbed.request.data == nil
      assert scrubbed.request.cookies == nil
      assert scrubbed.request.headers == nil
      assert scrubbed.request.env == nil
      assert scrubbed.user == %{}
      assert scrubbed.extra["api_key"] == "[REDACTED]"
      assert scrubbed.extra["nested"]["password"] == "[REDACTED]"
      assert scrubbed.extra["nested"]["safe"] == "kept"
    end

    test "the privacy page honestly discloses the server-side analytics posture", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "Mixpanel"
      assert html =~ "without an analytics identifier cookie"
      assert html =~ "campaign parameters that brought you here"
      refute html =~ "no third-party trackers in the application"
      # The "no third-party tracker or analytics script runs in your browser" claim must
      # carry the Paddle checkout carve-out — that page loads Paddle.js + Paddle Retain.
      assert html =~ ~r/aside from the Paddle checkout\s+page/
      # We do NOT honor DNT/GPC (first-party analytics isn't a sale) — the page
      # must not promise it.
      refute html =~ "Do Not Track"
      refute html =~ "Global Privacy Control"
    end

    test "the privacy page discloses every first-party cookie it actually sets", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      # We set more than one first-party functional cookie — the disclosure must not
      # undercount to a single session cookie.
      refute html =~ "We use one cookie"
      assert html =~ "session cookie"
      assert html =~ "recent-teams cookie"
      assert html =~ ~r/passwordless\s+sign-in/
      # The remember-me cookie mechanism exists in code but no sign-in path writes it,
      # so the page must not claim we set one.
      refute html =~ "remember-me cookie"
      # The no-tracker promise is retained, now scoped away from the Paddle checkout page.
      assert html =~ "no third-party tracker or analytics script runs in your browser"
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
      # and the honest dual-license characterization (Apache-2.0 edge + BUSL core).
      assert html =~ "twelve"
      assert html =~ "US $100"
      assert html =~ "Delaware"
      assert html =~ "Apache License 2.0"
      assert html =~ "Business Source License 1.1"
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
      # sign-in, SCIM, machine-API, or OAuth path would invite crawlers (and
      # scanners) at the authenticated control plane.
      # Anchor to the host so a public /docs/* page whose slug ends in a
      # private-route name (e.g. /docs/scim) isn't mistaken for the private
      # /scim API root — a private route leaks as its own <loc> or a subpath.
      for private <- ~w(/app /sign_in /scim /api /oauth) do
        refute body =~ "https://emisar.dev#{private}</loc>",
               "sitemap leaks a private route: #{private}"

        refute body =~ "https://emisar.dev#{private}/",
               "sitemap leaks a private route: #{private}"
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
    test "the install-mcp.sh URL quoted on /docs/connect-a-cli-client is the live endpoint",
         %{conn: conn} do
      # The docs page tells operators to `curl … /install-mcp.sh | sudo bash`;
      # that exact URL must resolve to the real script, never a 404/HTML —
      # a `curl | bash` integrity guarantee.
      html = conn |> get(~p"/docs/connect-a-cli-client") |> html_response(200)
      assert html =~ "https://emisar.dev/install-mcp.sh"

      conn = get(conn, ~p"/install-mcp.sh")
      assert response(conn, 200) =~ "#!/"
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "shellscript"
    end
  end

  # The home pillar-1 pack-source snippet as plain text: the <pre> that
  # follows the systemctl_status.yaml header, tags stripped and the
  # HEEx-escaped brace/quote entities decoded, so assertions compare
  # against the catalog's raw values instead of markup.
  defp catalog_snippet_text(html) do
    [snippet] =
      ~r{linux-core/actions/systemctl_status\.yaml\s*</div>\s*<pre[^>]*>(.*?)</pre>}s
      |> Regex.run(html, capture: :all_but_first)

    snippet
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&#123;", "{")
    |> String.replace("&#125;", "}")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  # Rendered prose carries the template's own line breaks and indentation, so
  # a sentence that reads as one line in the page is several in the HTML.
  # Collapsing runs of whitespace lets a copy assertion pin the sentence
  # instead of the formatter's wrapping.
  defp squish(html), do: html |> String.split() |> Enum.join(" ")

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
