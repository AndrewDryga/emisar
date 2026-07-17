defmodule EmisarWeb.MarketingController do
  @moduledoc """
  Public marketing pages: home, pricing, security, docs, changelog, about.

  These are served by Phoenix controllers (not LiveView) so they remain
  cacheable static-ish HTML, render instantly, and require no JS.

  All SEO meta tags (page_title, meta_description, canonical_url, og_*,
  optional json_ld) flow into `layouts/root.html.heex` via assigns.
  Pages are defined declaratively in @pages and the per-action defs are
  generated below — keeps "add a page" to one row, and prevents drift
  between routes, sitemap, and per-page metadata.
  """
  use EmisarWeb, :controller

  plug :put_layout, html: {EmisarWeb.Layouts, :app}

  @base "https://emisar.dev"

  # path | action | template | page_title | meta_description
  @pages [
    {"/security", :security, :security, "Security & compliance",
     "emisar's security model: pre-approved actions, redacted output, searchable audit, a hash-chained runner journal, and no SSH."},
    {"/docs", :docs, :docs, "Documentation — runner setup, action packs & MCP",
     "Documentation, action pack format, security model, and integration guides for emisar."},
    {"/about", :about, :about, "About", "Why emisar exists and how we built it."},
    {"/privacy", :privacy, :privacy, "Privacy Policy",
     "How emisar handles your data: what the control plane stores (account info, runner metadata, redacted audit events), what it never sees (raw secrets, full card numbers), where it lives, retention windows, and your export/delete rights."},
    {"/terms", :terms, :terms, "Terms of Service",
     "The terms for using emisar — the control plane that gives AI agents and humans approved infrastructure actions instead of SSH. Plans and billing, acceptable use, confidentiality, disclaimers, and account terms."},
    {"/dpa", :dpa, :dpa, "Data Processing Addendum",
     "emisar's standard Data Processing Addendum (DPA): the Article 28 terms we sign as your processor — roles, processing scope, our named subprocessors, security measures, US data residency with SCCs for EU/UK transfers, breach notification, and deletion on termination."},
    {"/refund-policy", :refund, :refund, "Refund Policy",
     "emisar's refund policy: Free is free; Team is billed monthly via Paddle and cancellable any time with access through the paid period; duplicate charges and billing errors are refunded in full."},
    {"/docs/mcp-reference", :docs_mcp_reference, :docs_mcp_reference,
     "MCP reference — methods, parameters, and errors",
     "The emisar MCP API reference for builders: twelve fixed discovery, action, operation, history, wait, and runbook tools; immutable pack and runner references; atomic mutation recovery; cancellation; signing; and actionable errors."},
    {"/docs/connect-an-llm", :connect_llm, :connect_llm, "Connect an LLM",
     "Connect Claude.ai and ChatGPT with remote MCP and OAuth, or use the emisar-mcp stdio bridge with Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI, and Grok CLI."},
    {"/docs/quickstart", :docs_quickstart, :docs_quickstart,
     "Quickstart — install the runner + run your first action",
     "Zero to your first audited action in five minutes: install the emisar runner on a Linux host with one command, watch it connect, run linux.uptime gated by policy and recorded in the audit trail, then point your LLM at the same catalog over MCP."},
    {"/docs/action-packs", :docs_action_packs, :docs_action_packs,
     "Action packs — YAML reference",
     "Full YAML schema reference for action packs: how to declare actions, argument validation, limits, redaction, and side-effects."},
    {"/docs/security-model", :docs_security_model, :docs_security_model, "Security model",
     "The emisar trust boundary: pre-approved actions, server-side re-validation, searchable audit, a hash-chained runner journal, and redaction before egress."},
    {"/docs/signed-dispatch", :docs_signed_dispatch, :docs_signed_dispatch,
     "Signed dispatch — a CA for runner actions, set up and rotated",
     "Make a runner execute only actions a real person signed in their MCP client. An offline Ed25519 CA issues short-lived, scoped certificates; a runner trusts the CA, not every key — so onboarding, rotation, and revocation never touch the control plane."},
    {"/use-cases/csi-data-loss", :usecase_csi_data_loss, :usecase_csi_data_loss,
     "Case study: a CSI driver wiped 33h of metrics — contained via emisar",
     "A real incident: democratic-csi ran mkfs over a live Pure LUN on a multipath race, wiping 33 hours of VictoriaMetrics data. An agent on emisar investigated through declared actions, stopped the bleed behind one approval, and landed the durable fix as reviewable infra — a guard that refuses to trust the driver, after the obvious one-line setting turned out to be a no-op."},
    {"/use-cases/ingress-502", :usecase_ingress_502, :usecase_ingress_502,
     "Case study: a fleet-wide 502 traced through five layers — via emisar",
     "A real incident: every app behind one anycast edge threw intermittent 502 Connection refused, yet every backend was healthy. An agent on emisar traced it across five layers — FRR, Traefik, Nomad, Consul — to a Traefik OOM loop and a wedged node still advertising a dead ingress, stopped the bleed behind gated approvals, and named the durable fix: health-gate the anycast so a node withdraws itself instead of black-holing traffic."},
    {"/compare/raw-ssh-for-ai", :compare_raw_ssh, :compare_raw_ssh,
     "Why not just give the LLM SSH? — honest comparison",
     "Comparison: raw SSH-for-AI agents vs an emisar action pack. Both run real commands; the difference is whose recovery you're betting on."},
    {"/compare/custom-mcp-server", :compare_custom_mcp, :compare_custom_mcp,
     "Custom MCP server vs emisar",
     "Custom MCP server vs emisar, honestly: the arg validation, pack integrity, policy, approvals, per-user scopes, redaction, audit, and reconnect handling you'd build and own for production agent access — and emisar's real tradeoffs in return."},
    {"/compare/copy-paste-ai-ops", :compare_copy_paste, :compare_copy_paste,
     "Copy-pasting between an LLM and your terminal",
     "See what changes when an LLM can use a small set of approved actions instead of waiting for you to paste logs, commands, and results back and forth."},
    {"/how-it-works", :how_it_works, :how_it_works, "How emisar works",
     "How emisar works: an agent calls one declared action; the control plane checks the pack hash and policy; a human approves anything risky; the outbound-only runner re-validates and executes on your host; and every step lands in a searchable audit, mirrored to a tamper-evident hash-chained journal on your host. The five-gate path from intent to receipt."},
    {"/trust", :trust, :trust, "Trust Center — security, infrastructure & assurance",
     "Review the controls protecting emisar: outbound-only runners, signed dispatch, private Google Cloud infrastructure, DNSSEC, hardened delivery, independent monitoring, audit evidence, DPA, subprocessors, and insurance."},
    {"/zero-trust", :zero_trust, :zero_trust, "Zero Trust for AI Agents",
     "Anthropic's Zero Trust for AI Agents framework calls for least agency, deny-by-default tools, human approval for high-risk actions, and an immutable audit trail. See how emisar enforces that exact control set between an LLM and your infrastructure — including the approval gates, just-in-time access, and SIEM export the framework files under its top tiers, shipped by default on emisar's Free plan."},
    {"/docs/publishing-packs", :docs_publishing_packs, :docs_publishing_packs,
     "Author your own action pack",
     "Write, validate, install, and trust an emisar action pack you maintain yourself — pack.yaml, action YAMLs, content-hash trust, and fleet rollout. Plus when (and how) to propose a genuinely generic pack to the curated public registry."},
    {"/docs/pack-registry", :docs_pack_registry, :docs_pack_registry,
     "Host your own pack registry",
     "Run a private emisar pack registry on infrastructure you control — it's a static file layout over HTTPS. Build it with packctl (the same tool that publishes the public registry), host it on GCS, S3, or any web server, and install fleet-wide with hash-pinned trust. Distribution and trust stay deliberately separate."},
    {"/docs/policies-and-approvals", :docs_policies, :docs_policies,
     "Policies & approvals — control what runs",
     "How emisar decides allow / require-approval / deny per action: risk-tier defaults, ordered per-action overrides, human approvals with a 24-hour TTL, and revocable standing grants scoped to a key, action, runner, and arguments."},
    {"/docs/runbooks", :docs_runbooks, :docs_runbooks,
     "Runbooks — saved, gated operational sequences",
     "Author versioned runbooks in a form editor, target runners or groups per step, dispatch with per-step policy gating and halt-on-failure — and let your LLM read and run them over MCP."},
    {"/docs/teams-and-access", :docs_teams, :docs_teams, "Teams, roles & access",
     "The emisar access model: owner/admin/operator/viewer roles, invitations, per-member runner scopes that hide out-of-scope hosts, account-wide MFA enforcement, session management, and scoped revocable API keys."},
    {"/docs/sso", :docs_sso, :docs_sso, "Single sign-on & directory sync",
     "OIDC SSO (Team and Enterprise) + Enterprise SCIM 2.0 directory sync for emisar — sign in with Google Workspace, Okta, or Keycloak; offboarding in your IdP revokes emisar access automatically."},
    {"/docs/runners", :docs_runners, :docs_runners, "Operating your runner fleet",
     "Groups and labels, single-use enrollment keys, pack credentials via inherit_env, updating the binary and packs, reconnect and stuck-run semantics, host-side troubleshooting, and clean removal."},
    {"/docs/deployment", :docs_deployment, :docs_deployment, "Deploying emisar in production",
     "From one runner to a governed fleet: a reference architecture, a phased rollout, best practices by layer, two worked examples, and a go-live checklist your security review will recognize."},
    {"/docs/audit-and-siem", :docs_audit, :docs_audit, "The audit trail & SIEM export",
     "What emisar records, reading it in the dashboard, streaming NDJSON to your SIEM with a read-only audit:read key and cursor pagination, and verifying the hash-chained runner journal."}
  ]

  # Home FAQ — the single source of truth for both the visible FAQ
  # accordion (rendered from the `faqs` assign) and the FAQPage JSON-LD
  # below. Keeping them in one list is what lets Google's rich result
  # match visible content without the two drifting apart.
  @home_faqs [
    {"Can the LLM run anything it wants?",
     "No. The runner only exposes actions declared in a content-addressed pack. Anything else is rejected at the runner before it touches your shell. The model literally cannot see undeclared commands."},
    {"What can it actually do?",
     "Read and tail logs, query metrics, inspect processes, memory, disk, and containers, check your databases, and trace DNS, TLS, and connectivity — across your whole fleet. And, behind approval, act: restart a unit, stop a runaway job, fail over, scale. It's a finite catalog of declared actions, never a raw shell."},
    {"Where do approvals happen?",
     "In the web UI today. The approver sees the actor, the arguments, the target host, and the policy rule that triggered the gate. One click to allow, one to deny."},
    {"Do I have to approve every action?",
     "No — you decide per action. Reads run automatically; you reserve approvals for the risky, mutating ones. Policy sets allow / require-approval / deny by risk tier, with per-action overrides, and the destructive verbs are deny-by-default."},
    {"What if my runner dies mid-run?",
     "On Linux, the runner kills the child and its process group when it exits (PR_SET_PDEATHSIG + setpgid), so a dead runner doesn't leave the action running. If the runner stays offline, the cloud's dispatch-timeout sweep marks its in-flight runs as errored with the reason within minutes, so nothing reads as running forever."},
    {"Is this MCP-compatible?",
     "Yes. Claude.ai and ChatGPT connect to emisar's remote JSON-RPC MCP server through OAuth. Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI, and Grok CLI can use the emisar-mcp stdio bridge."},
    {"Can I self-host the control plane?",
     "The current product uses the hosted emisar control plane. The repository includes deployable control-plane code for evaluation, but supported self-hosted and air-gapped deployments are not generally available today. Contact us if that boundary is a requirement."},
    {"What about secrets?",
     "The runner runs a redaction pipeline on every stdout/stderr stream before forwarding. Patterns are declared per-action; sane defaults catch AWS keys, JWTs, and bearer tokens. The cloud receives only the redacted output stream — never the raw bytes."}
  ]

  # The home page has bespoke JSON-LD; keep it as its own def. Every
  # other page is generated below from @pages.
  def home(conn, _params) do
    org_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
          "@graph" => [
            %{
              "@type" => "Organization",
              "name" => "emisar",
              "url" => @base,
              "logo" => @base <> "/images/brand/emisar-logo.png",
              "description" =>
                "Give AI agents approved infrastructure actions, not SSH. Pack trust, policy gates, approvals, searchable audit, and a hash-chained runner journal."
            },
            %{
              "@type" => "SoftwareApplication",
              "name" => "emisar",
              "applicationCategory" => "DeveloperApplication",
              "operatingSystem" => "Linux, macOS",
              "url" => @base,
              "offers" => %{
                "@type" => "Offer",
                "priceCurrency" => "USD",
                "price" => "0",
                "description" => "Free for up to 3 runners"
              }
            },
            %{
              "@type" => "FAQPage",
              "mainEntity" =>
                Enum.map(@home_faqs, fn {question, answer} ->
                  %{
                    "@type" => "Question",
                    "name" => question,
                    "acceptedAnswer" => %{"@type" => "Answer", "text" => answer}
                  }
                end)
            }
          ]
        },
        escape: :html_safe
      )

    render(conn, :home,
      page_title: "Secure infrastructure access for AI agents — approved actions, not SSH",
      meta_description:
        "Connect Claude, Cursor, ChatGPT, or any MCP agent to your infrastructure through approved, audited actions instead of SSH. Set up in five minutes.",
      canonical_url: @base <> "/",
      faqs: @home_faqs,
      pack_count: EmisarWeb.PacksRegistry.pack_count(),
      action_count: delimit_int(EmisarWeb.PacksRegistry.action_count()),
      json_ld: org_ld
    )
  end

  # Pricing FAQ — single source of truth for the visible accordion and
  # the FAQPage JSON-LD, so Google's rich result matches the on-page text.
  @pricing_faqs [
    {"What counts as a \"runner\"?",
     "One installation of the emisar binary on one host — VM, container, or bare metal. Run as many runners as your plan allows. Human users are unlimited on Team and Enterprise."},
    {"Do you store the output of my commands?",
     "We store metadata (who, when, which action, exit code) and a configurable slice of stdout/stderr for the audit log. Output is redacted on the runner before anything is forwarded — 20 built-in patterns plus your own per-action rules — so the control plane stores only the redacted stream, never the raw bytes."},
    {"How does billing work?",
     "Paid plans are billed per runner through Paddle, our Merchant of Record. You get monthly invoices, and Paddle handles sales tax and VAT. We never see or store full card numbers."},
    {"Can I self-host?",
     "The current product uses the hosted emisar control plane. The runner, MCP bridge, and packs are Apache-2.0 open source, and the repository includes deployable control-plane code (Business Source License) for evaluation — but supported self-hosted and air-gapped deployments are not generally available today. Tell us if that boundary is a requirement."},
    {"Can I cancel any time?",
     "Yes. Cancel from billing settings and you drop back to Free at the end of the current billing period. Your audit data is retained per the Free retention window."},
    {"Do you support SSO and SCIM?",
     "Yes. OIDC single sign-on (Google Workspace, Okta, or Keycloak, or any compliant provider) is on Team and Enterprise; SCIM 2.0 directory sync is Enterprise. Offboard someone in your IdP and emisar ends their sessions and revokes their keys automatically — no manual cleanup."},
    {"Do you offer startup discounts?",
     "Yes. Email sales@emisar.dev with your YC or pre-seed letter and we'll take it from there."}
  ]

  # Product + per-plan Offer + FAQ rich data for the pricing page. Prices
  # mirror `Emisar.Billing.@plans` (Free = 3 runners, Team = $20/runner).
  @pricing_ld Jason.encode!(
                %{
                  "@context" => "https://schema.org",
                  "@graph" => [
                    %{
                      "@type" => "Product",
                      "name" => "emisar",
                      "description" =>
                        "Approved infrastructure actions for AI agents — policy, approvals, searchable audit, and a hash-chained runner journal instead of SSH.",
                      "brand" => %{"@type" => "Brand", "name" => "emisar"},
                      "offers" => [
                        %{
                          "@type" => "Offer",
                          "name" => "Free",
                          "price" => "0",
                          "priceCurrency" => "USD",
                          "description" => "Up to 3 runners, 1 user, 7-day audit retention"
                        },
                        %{
                          "@type" => "Offer",
                          "name" => "Team",
                          "price" => "20",
                          "priceCurrency" => "USD",
                          "description" =>
                            "Per runner / month. Unlimited users, 90-day audit retention"
                        }
                      ]
                    },
                    %{
                      "@type" => "FAQPage",
                      "mainEntity" =>
                        Enum.map(@pricing_faqs, fn {question, answer} ->
                          %{
                            "@type" => "Question",
                            "name" => question,
                            "acceptedAnswer" => %{"@type" => "Answer", "text" => answer}
                          }
                        end)
                    }
                  ]
                },
                escape: :html_safe
              )

  def pricing(conn, _params) do
    render(conn, :pricing,
      page_title: "Pricing — per runner, not per seat",
      meta_description:
        "Per runner, not per seat. Free covers 3 runners and 1 user; Team is $20 per runner per month with unlimited users and 90-day audit retention; Enterprise is custom.",
      canonical_url: @base <> "/pricing",
      og_image: @base <> "/images/og/og-pricing.png",
      faqs: @pricing_faqs,
      json_ld: @pricing_ld
    )
  end

  # Changelog — data-driven from EmisarWeb.Changelog so the page and the
  # /changelog.xml RSS feed render from one source and never drift.
  def changelog(conn, _params) do
    # Home → Changelog breadcrumb — the data-driven rewrite dropped it; this
    # restores the BreadcrumbList every other generated/bespoke page emits.
    json_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
          "@graph" => [
            %{
              "@type" => "BreadcrumbList",
              "itemListElement" =>
                breadcrumb_items([{"Home", @base <> "/"}, {"Changelog", @base <> "/changelog"}])
            }
          ]
        },
        escape: :html_safe
      )

    render(conn, :changelog,
      page_title: "Changelog",
      meta_description:
        "Shipping notes for emisar — the control plane that gives AI agents approved infrastructure actions instead of SSH. Signed dispatch, SSO and SCIM, approvals and audit, the action-pack catalog, and the redesigned site and identity.",
      canonical_url: @base <> "/changelog",
      entries: EmisarWeb.Changelog.entries(),
      json_ld: json_ld
    )
  end

  # GET /changelog.xml — RSS 2.0 from the same EmisarWeb.Changelog source.
  def changelog_feed(conn, _params) do
    items =
      Enum.map_join(EmisarWeb.Changelog.entries(), "\n", fn entry ->
        url = EmisarWeb.Changelog.entry_url(entry)

        """
          <item>
            <title>#{xml_escape(entry.title)}</title>
            <link>#{url}</link>
            <guid isPermaLink="true">#{url}</guid>
            <pubDate>#{EmisarWeb.Changelog.rss_date(entry.date)}</pubDate>
            <description>#{xml_escape(entry.summary)}</description>
          </item>\
        """
      end)

    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>emisar changelog</title>
        <link>#{@base}/changelog</link>
        <description>Shipping notes from the emisar team.</description>
        <language>en-us</language>
    #{items}
      </channel>
    </rss>
    """

    conn
    |> put_resp_content_type("application/rss+xml")
    |> send_resp(200, body)
  end

  # Minimal XML text-content escape (&, <, > — the three required in element text).
  defp xml_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # The /use-cases index — a hub linking the real-incident case studies, which
  # were previously reachable only from the home page and footer. Its own
  # bespoke JSON-LD (BreadcrumbList + ItemList) so the case studies list in
  # search results.
  def use_cases(conn, _params) do
    cases = [
      {"The 33-hour wipe: a CSI driver reformatted a live LUN",
       @base <> "/use-cases/csi-data-loss"},
      {"The fleet-wide 502 that no backend was causing", @base <> "/use-cases/ingress-502"}
    ]

    json_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
          "@graph" => [
            %{
              "@type" => "BreadcrumbList",
              "itemListElement" =>
                breadcrumb_items([{"Home", @base <> "/"}, {"Use cases", @base <> "/use-cases"}])
            },
            %{
              "@type" => "ItemList",
              "name" => "emisar use cases",
              "itemListElement" =>
                cases
                |> Enum.with_index(1)
                |> Enum.map(fn {{name, url}, position} ->
                  %{"@type" => "ListItem", "position" => position, "url" => url, "name" => name}
                end)
            }
          ]
        },
        escape: :html_safe
      )

    render(conn, :use_cases,
      page_title: "Use cases — real incidents emisar contained",
      meta_description:
        "Real production incidents worked end to end through emisar: a CSI driver's 33-hour data wipe and a fleet-wide 502 that no backend was causing — each investigated through declared actions, stopped behind one approval, every step audited.",
      canonical_url: @base <> "/use-cases",
      json_ld: json_ld
    )
  end

  # Guides — top-of-funnel long-form. Each is its own template (the body);
  # this list drives the index cards, per-guide meta + TechArticle JSON-LD,
  # and the sitemap. {slug, action/template, title, dek, date, read_time, meta}.
  @guides [
    {"give-ai-agents-safe-production-access", :guide_safe_access,
     "How to give an AI agent safe access to production",
     "You don't hand it your SSH key. You give it a small, declared catalog of actions, gate the risky ones behind a human, and audit every call. Here's the pattern — and why it's the one that holds up.",
     "June 2026", "8 min read",
     "How to give an AI agent safe access to production infrastructure: why SSH is the wrong door, the declared-catalog + policy-gate + human-approval + audit pattern that actually holds, and how it maps to Anthropic's Zero-Trust for AI Agents controls."},
    {"ai-agents-and-ssh-the-risks", :guide_ssh_risks,
     "Should you give an AI agent SSH? The risks, and the alternative",
     "Handing an agent a shell on prod is the fastest way to give it access — and the fastest way to regret it. The real risks, why \"just be careful\" doesn't hold, and the alternative that keeps the capability without the blast radius.",
     "June 2026", "7 min read",
     "The risks of giving an AI agent SSH access to production — full blast radius, prompt injection into arbitrary commands, no gate before the action and no durable record after — and the declared-action-catalog alternative that keeps the real commands but adds a policy gate, human approval, and a hash-chained audit journal on the host."}
  ]
  @guide_summaries Enum.map(@guides, fn {slug, _action, title, dek, date, read_time, _desc} ->
                     %{slug: slug, title: title, dek: dek, date: date, read_time: read_time}
                   end)

  def guides(conn, _params) do
    list_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
          "@graph" => [
            %{
              "@type" => "BreadcrumbList",
              "itemListElement" =>
                breadcrumb_items([{"Home", @base <> "/"}, {"Guides", @base <> "/guides"}])
            },
            %{
              "@type" => "ItemList",
              "itemListElement" =>
                @guides
                |> Enum.with_index(1)
                |> Enum.map(fn {{slug, _action, title, _dek, _date, _read_time, _desc}, position} ->
                  %{
                    "@type" => "ListItem",
                    "position" => position,
                    "name" => title,
                    "url" => @base <> "/guides/" <> slug
                  }
                end)
            }
          ]
        },
        escape: :html_safe
      )

    render(conn, :guides_index,
      page_title: "Guides — AI agents and production infrastructure",
      meta_description:
        "Practical guides on giving AI agents safe, audited access to production infrastructure — the patterns that hold, the risks of the shortcuts, and the honest trade-offs.",
      canonical_url: @base <> "/guides",
      og_image: @base <> "/images/og/og-guides.png",
      json_ld: list_ld,
      guides: @guide_summaries
    )
  end

  # Per-action JSON-LD, injected into the generated def below when present.
  @page_json_ld %{}

  # Per-section OG card (in priv/static/images/og/) for the generated pages;
  # everything else falls back to the default emisar-og.webp in the layout.
  # Bespoke actions (pricing, guides) set :og_image inline.
  @og_images %{security: "og-security", trust: "og-security", zero_trust: "og-security"}

  # Generate one `def <action>(conn, _)` per row. Keeping this in module
  # body (not a macro) so the action names show up directly in routes,
  # stacktraces, and grep.
  for {path, action, template, title, description} <- @pages do
    base_attrs = [page_title: title, canonical_url: @base <> path]

    attrs =
      if description,
        do: Keyword.put(base_attrs, :meta_description, description),
        else: base_attrs

    # BreadcrumbList structured data for every generated page (home + pricing
    # carry their own bespoke JSON-LD). Derived from the path — Home → Docs
    # (for /docs/*) → this page — so search results can show the hierarchy. A
    # bespoke `@page_json_ld` entry, when present, overrides the breadcrumb.
    docs_crumb =
      if String.starts_with?(path, "/docs/"), do: [{"Docs", @base <> "/docs"}], else: []

    crumbs = [{"Home", @base <> "/"}] ++ docs_crumb ++ [{title, @base <> path}]

    breadcrumb_node = %{
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        crumbs
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, item}, position} ->
          %{"@type" => "ListItem", "position" => position, "name" => name, "item" => item}
        end)
    }

    # Docs pages also carry TechArticle structured data (richer article
    # results); every other page keeps the bare BreadcrumbList it always had.
    default_ld =
      cond do
        String.starts_with?(path, "/docs") ->
          Jason.encode!(
            %{
              "@context" => "https://schema.org",
              "@graph" => [
                breadcrumb_node,
                %{
                  "@type" => "TechArticle",
                  "headline" => title,
                  "description" => description,
                  "author" => %{"@type" => "Organization", "name" => "emisar", "url" => @base},
                  "publisher" => %{
                    "@type" => "Organization",
                    "name" => "emisar",
                    "logo" => %{
                      "@type" => "ImageObject",
                      "url" => @base <> "/images/brand/emisar-logo.png"
                    }
                  },
                  "mainEntityOfPage" => @base <> path
                }
              ]
            },
            escape: :html_safe
          )

        # The procurement (/trust) + framework (/zero-trust) pages carry a
        # SoftwareApplication node so they surface as the product in rich
        # results — the rest of the generated surface keeps a bare breadcrumb.
        action in [:trust, :zero_trust] ->
          Jason.encode!(
            %{
              "@context" => "https://schema.org",
              "@graph" => [
                breadcrumb_node,
                %{
                  "@type" => "SoftwareApplication",
                  "name" => "emisar",
                  "applicationCategory" => "SecurityApplication",
                  "operatingSystem" => "Linux, macOS",
                  "url" => @base <> path,
                  "description" => description,
                  "offers" => %{
                    "@type" => "Offer",
                    "priceCurrency" => "USD",
                    "price" => "0",
                    "description" => "Free for up to 3 runners"
                  }
                }
              ]
            },
            escape: :html_safe
          )

        true ->
          Jason.encode!(Map.put(breadcrumb_node, "@context", "https://schema.org"),
            escape: :html_safe
          )
      end

    attrs = Keyword.put(attrs, :json_ld, Map.get(@page_json_ld, action, default_ld))

    attrs = if action == :docs, do: Keyword.put(attrs, :guides, @guide_summaries), else: attrs

    attrs =
      case Map.get(@og_images, action) do
        nil -> attrs
        file -> Keyword.put(attrs, :og_image, @base <> "/images/og/" <> file <> ".png")
      end

    template_atom = template
    attrs_literal = Macro.escape(attrs)

    def unquote(action)(conn, _params) do
      render(conn, unquote(template_atom), unquote(attrs_literal))
    end
  end

  # One dynamic action for every guide. The guide template (named by the
  # @guides action atom) hardcodes its own <.guide_page> chrome; this supplies
  # the page title, meta, canonical, and TechArticle JSON-LD, and 404s an
  # unknown slug the same way pack_detail does.
  def guide(conn, %{"slug" => slug}) do
    case Enum.find(@guides, fn {s, _action, _title, _dek, _date, _read_time, _desc} ->
           s == slug
         end) do
      nil ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> put_view(html: EmisarWeb.ErrorHTML)
        |> render(:"404")

      {^slug, action, title, _dek, _date, _read_time, description} ->
        path = "/guides/" <> slug

        article_ld =
          Jason.encode!(
            %{
              "@context" => "https://schema.org",
              "@graph" => [
                %{
                  "@type" => "BreadcrumbList",
                  "itemListElement" =>
                    breadcrumb_items([
                      {"Home", @base <> "/"},
                      {"Guides", @base <> "/guides"},
                      {title, @base <> path}
                    ])
                },
                %{
                  "@type" => "TechArticle",
                  "headline" => title,
                  "description" => description,
                  "author" => %{"@type" => "Organization", "name" => "emisar", "url" => @base},
                  "publisher" => %{
                    "@type" => "Organization",
                    "name" => "emisar",
                    "logo" => %{
                      "@type" => "ImageObject",
                      "url" => @base <> "/images/brand/emisar-logo.png"
                    }
                  },
                  "mainEntityOfPage" => @base <> path
                }
              ]
            },
            escape: :html_safe
          )

        render(conn, action,
          page_title: title,
          meta_description: description,
          canonical_url: @base <> path,
          json_ld: article_ld
        )
    end
  end

  # -- Packs registry -------------------------------------------------
  #
  # `/packs` lists every published pack; `/packs/:id` is the per-pack
  # detail page (description, actions, install snippet, source link).
  # The registry data is hardcoded in `EmisarWeb.PacksRegistry`; future
  # work may load from a remote manifest so third-party packs can list
  # themselves without a code change.

  def packs(conn, _params) do
    packs = EmisarWeb.PacksRegistry.list()

    json_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
          "@graph" => [
            %{
              "@type" => "BreadcrumbList",
              "itemListElement" =>
                breadcrumb_items([{"Home", @base <> "/"}, {"Action packs", @base <> "/packs"}])
            },
            %{
              "@type" => "ItemList",
              "name" => "emisar action packs",
              "itemListElement" =>
                packs
                |> Enum.with_index(1)
                |> Enum.map(fn {pack, position} ->
                  %{
                    "@type" => "ListItem",
                    "position" => position,
                    "url" => @base <> "/packs/" <> pack.id,
                    "name" => pack.name
                  }
                end)
            }
          ]
        },
        escape: :html_safe
      )

    render(conn, :packs,
      grouped: EmisarWeb.PacksRegistry.grouped(),
      pack_count: EmisarWeb.PacksRegistry.pack_count(),
      action_count: delimit_int(EmisarWeb.PacksRegistry.action_count()),
      page_title: "Action packs registry",
      meta_description:
        "Browse the registry of action packs you can install on your emisar runner — Postgres, Cassandra, Linux core, Docker, AWS, and more. Each pack ships a typed catalog of actions an LLM can call.",
      canonical_url: @base <> "/packs",
      json_ld: json_ld
    )
  end

  def pack_detail(conn, %{"id" => id}) do
    case EmisarWeb.PacksRegistry.get(id) do
      nil ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> put_view(html: EmisarWeb.ErrorHTML)
        |> render(:"404")

      pack ->
        url = @base <> "/packs/" <> pack.id

        json_ld =
          Jason.encode!(
            %{
              "@context" => "https://schema.org",
              "@graph" => [
                %{
                  "@type" => "BreadcrumbList",
                  "itemListElement" =>
                    breadcrumb_items([
                      {"Home", @base <> "/"},
                      {"Action packs", @base <> "/packs"},
                      {pack.name, url}
                    ])
                },
                %{
                  "@type" => "SoftwareApplication",
                  "name" => "#{pack.name} action pack",
                  "description" => pack.description,
                  "url" => url,
                  "applicationCategory" => "DeveloperApplication",
                  "operatingSystem" => pack_operating_system(pack),
                  "softwareVersion" => pack.version,
                  "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"}
                }
              ]
            },
            escape: :html_safe
          )

        render(conn, :pack_detail,
          pack: pack,
          page_title: "#{pack.name} pack",
          meta_description: pack.description,
          canonical_url: url,
          json_ld: json_ld
        )
    end
  end

  # Shared BreadcrumbList itemListElement builder — ordered {name, url}
  # crumbs. The compile-time @pages defs build their own inline (they run
  # before this is compiled); the runtime pack pages reuse this.
  defp breadcrumb_items(crumbs) do
    crumbs
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, item}, position} ->
      %{"@type" => "ListItem", "position" => position, "name" => name, "item" => item}
    end)
  end

  defp pack_operating_system(%{requires_os: [_ | _] = os}), do: Enum.join(os, ", ")
  defp pack_operating_system(_), do: "Linux, macOS"

  # Thousands separator for display counts ("1187" → "1,187").
  defp delimit_int(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1,")
  end

  # POST /subscribe — captures an email from the footer's product-updates form.
  # Public + unauthenticated; CSRF-protected by the :browser pipeline.
  def subscribe(conn, params), do: capture_subscribe(conn, params)

  # Honeypot: bots fill the hidden "company" field; real users never see it, so a
  # non-blank value is a bot — accept silently and store nothing.
  defp capture_subscribe(conn, %{"company" => filled}) when filled not in [nil, ""],
    do: thank_subscriber(conn)

  defp capture_subscribe(conn, params) do
    case Emisar.Marketing.capture_signup(%{email: params["email"], source: params["source"]}) do
      {:ok, _signup} ->
        EmisarWeb.Analytics.track_lead_captured(conn, params["source"] || "footer")
        thank_subscriber(conn)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "That doesn't look like a valid email — mind trying again?")
        |> redirect(to: return_path(conn))
    end
  end

  defp thank_subscriber(conn) do
    conn
    |> put_flash(
      :info,
      "You're subscribed — we'll email you when we ship something major."
    )
    |> redirect(to: return_path(conn))
  end

  # Back to the footer form the POST came from — anchored to #updates so the page
  # doesn't jump to the top — but only ever a local path: the referer's host is
  # discarded, so it can't become an open redirect.
  defp return_path(conn) do
    path =
      case List.first(get_req_header(conn, "referer")) do
        "http" <> _ = referer -> referer |> URI.parse() |> local_path()
        _ -> "/"
      end

    path <> "#updates"
  end

  defp local_path(%URI{path: "/" <> _ = path}), do: path
  defp local_path(_), do: "/"
end
