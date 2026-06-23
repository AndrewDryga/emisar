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
    {"/docs", :docs, :docs, "Docs",
     "Documentation, action pack format, security model, and integration guides for emisar."},
    {"/about", :about, :about, "About", "Why emisar exists and how we built it."},
    {"/privacy", :privacy, :privacy, "Privacy Policy",
     "How emisar handles your data: what the control plane stores (account info, runner metadata, redacted audit events), what it never sees (raw secrets, full card numbers), where it lives, retention windows, and your export/delete rights."},
    {"/terms", :terms, :terms, "Terms of Service",
     "The terms for using emisar — the control plane that gives AI agents and humans approved infrastructure actions instead of SSH. Plans and billing, acceptable use, confidentiality, disclaimers, and account terms."},
    {"/refund-policy", :refund, :refund, "Refund Policy",
     "emisar's refund policy: Free is free; Team is billed monthly via Paddle and cancellable any time with access through the paid period; duplicate charges and billing errors are refunded in full."},
    {"/docs/connect-an-llm", :connect_llm, :connect_llm, "Connect an LLM",
     "Connect Claude.ai and ChatGPT with remote MCP and OAuth, or use the emisar-mcp stdio bridge with Claude Code, Claude Desktop, Cursor, Gemini CLI, and Codex CLI."},
    {"/docs/quickstart", :docs_quickstart, :docs_quickstart,
     "Quickstart — install the runner + run your first action",
     "Zero to your first audited action in five minutes: install the emisar runner on a Linux host with one command, watch it connect, run linux.uptime gated by policy and recorded in the audit trail, then point your LLM at the same catalog over MCP."},
    {"/docs/action-packs", :docs_action_packs, :docs_action_packs,
     "Action packs — YAML reference",
     "Full YAML schema reference for action packs: how to declare actions, argument validation, limits, redaction, and side-effects."},
    {"/docs/security-model", :docs_security_model, :docs_security_model, "Security model",
     "The emisar trust boundary: pre-approved actions, server-side re-validation, searchable audit, a hash-chained runner journal, and redaction before egress."},
    {"/use-cases/cassandra-ops", :usecase_cassandra, :usecase_cassandra,
     "Cassandra case study: containing a runaway compaction",
     "A real-shape Cassandra incident: a hand-run major compaction melts the read path. An AI agent investigates through declared nodetool actions — status, proxyhistograms, tpstats, compactionstats — then aborts it with nodetool stop behind one human approval. Node-lifecycle commands stay denied by default."},
    {"/use-cases/postgres-ops", :usecase_postgres, :usecase_postgres,
     "Postgres case study: clearing a wedged lock chain",
     "A real-shape Postgres incident: a crashed migration leaves an idle-in-transaction backend holding a lock and the whole app queues behind it. An AI agent investigates through read-only psql actions, then terminates the backend behind one approval — no raw SQL, no DDL, every step audited."},
    {"/use-cases/csi-data-loss", :usecase_csi_data_loss, :usecase_csi_data_loss,
     "Case study: a CSI driver wiped 33h of metrics — contained via emisar",
     "A real incident: democratic-csi ran mkfs over a live Pure LUN on a multipath race, wiping 33 hours of VictoriaMetrics data. An agent on emisar investigated through declared actions, stopped the bleed behind one approval, and landed the durable fix as reviewable infra — a guard that refuses to trust the driver, after the obvious one-line setting turned out to be a no-op."},
    {"/compare/raw-ssh-for-ai", :compare_raw_ssh, :compare_raw_ssh,
     "Why not just give the LLM SSH? — honest comparison",
     "Comparison: raw SSH-for-AI agents vs an emisar action pack. Both run real commands; the difference is whose recovery you're betting on."},
    {"/compare/custom-mcp-server", :compare_custom_mcp, :compare_custom_mcp,
     "Custom MCP server vs emisar",
     "Custom MCP server vs emisar, honestly: the arg validation, pack integrity, policy, approvals, per-user scopes, redaction, audit, and reconnect handling you'd build and own for production agent access — and emisar's real tradeoffs in return."},
    {"/demo", :demo, :demo, "Book a demo",
     "See emisar on your own infrastructure — a 30-minute walkthrough with the engineers who built it: connect a runner, gate a real action, and get straight answers on the trust model, SSO/SCIM, compliance, and per-runner pricing for your fleet."},
    {"/trust", :trust, :trust, "Trust & compliance",
     "Everything a security or procurement team needs to evaluate emisar, in one place: SSO + SCIM, enforced MFA, RBAC and per-user runner scopes, the hash-chained audit and SIEM export, US data residency and encryption, retention and deletion rights, subprocessors, the signed-dispatch trust boundary — and our current compliance posture, stated honestly."},
    {"/zero-trust", :zero_trust, :zero_trust, "Zero Trust for AI Agents",
     "Anthropic's Zero Trust for AI Agents framework calls for least agency, deny-by-default tools, human approval for high-risk actions, and an immutable audit trail. See how emisar enforces that exact control set between an LLM and your infrastructure — including the approval gates, just-in-time access, and SIEM export the framework files under its top tiers, shipped by default on emisar's Free plan."},
    {"/docs/publishing-packs", :docs_publishing_packs, :docs_publishing_packs,
     "Author your own action pack",
     "Write, validate, install, and trust an emisar action pack you maintain yourself — pack.yaml, action YAMLs, content-hash trust, and fleet rollout. Plus when (and how) to propose a genuinely generic pack to the curated public registry."},
    {"/docs/policies-and-approvals", :docs_policies, :docs_policies,
     "Policies & approvals — control what runs",
     "How emisar decides allow / require-approval / deny per action: risk-tier defaults, ordered per-action overrides, human approvals with a 24-hour TTL, and revocable standing grants scoped to a key, action, runner, and arguments."},
    {"/docs/runbooks", :docs_runbooks, :docs_runbooks,
     "Runbooks — saved, gated operational sequences",
     "Author versioned runbooks in a form editor, target runners or groups per step, dispatch with per-step policy gating and halt-on-failure — and let your LLM read them as playbooks over MCP."},
    {"/docs/teams-and-access", :docs_teams, :docs_teams, "Teams, roles & access",
     "The emisar access model: owner/admin/operator/viewer roles, invitations, per-member runner scopes that hide out-of-scope hosts, account-wide MFA enforcement, session management, and scoped revocable API keys."},
    {"/docs/sso", :docs_sso, :docs_sso, "Single sign-on & directory sync",
     "Enterprise OIDC SSO + SCIM 2.0 directory sync for emisar — sign in with Google Workspace, Okta, or Keycloak; offboarding in your IdP revokes emisar access automatically."},
    {"/docs/runners", :docs_runners, :docs_runners, "Operating your runner fleet",
     "Groups and labels, single-use enrollment keys, pack credentials via inherit_env, updating the binary and packs, reconnect and stuck-run semantics, host-side troubleshooting, and clean removal."},
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
    {"Where do approvals happen?",
     "In the web UI today. The approver sees the actor, the arguments, the target host, and the policy rule that triggered the gate. One click to allow, one to deny."},
    {"What if my runner dies mid-run?",
     "Child processes are reaped with PR_SET_PDEATHSIG on Linux — no zombies, no orphans. If the runner stays offline, the cloud's dispatch-timeout sweep marks its in-flight runs as errored with the reason within minutes, so nothing reads as running forever."},
    {"Is this MCP-compatible?",
     "Yes. Claude.ai and ChatGPT connect to emisar's remote JSON-RPC MCP server through OAuth. Claude Code, Claude Desktop, Cursor, Gemini CLI, and Codex CLI can use the emisar-mcp stdio bridge."},
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
                "Give AI tools approved infrastructure actions, not SSH. Pack trust, policy gates, approvals, searchable audit, and a hash-chained runner journal."
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
      page_title: "Give AI tools approved infrastructure actions, not SSH",
      meta_description:
        "Connect any MCP client to a finite action catalog, enforced on-host with pack trust, policy gates, human approvals, a searchable audit trail, and a hash-chained runner journal.",
      canonical_url: @base <> "/",
      faqs: @home_faqs,
      pack_count: EmisarWeb.PacksRegistry.pack_count(),
      action_count: delimit_int(EmisarWeb.PacksRegistry.action_count()),
      json_ld: org_ld
    )
  end

  # The /ai landing page — a benefit-first explainer of what emisar is, aimed at
  # someone whose mental model is "my AI assistant can't see my infra." Its own
  # bespoke JSON-LD (SoftwareApplication + FAQ), like home + pricing.
  #
  # Single source of truth for both the visible FAQ accordion and the FAQPage
  # rich data — one list keeps Google's result matched to the on-page text.
  @ai_faqs [
    {"Is it safe to let an AI touch production?",
     "That's the whole design. The model can only call actions declared in a content-hashed pack — undeclared commands don't exist to it. Reads run on policy; anything risky stops for a human approval that shows the actor, the arguments, and the target host. There's no SSH and no standing access, every argument is re-validated on the host, and every call lands in the audit trail."},
    {"What can it actually do?",
     "Read and tail logs, query metrics, inspect processes, memory, disk, and containers, check your databases, and trace DNS, TLS, and connectivity — across your whole fleet. And, behind approval, act: restart a unit, stop a runaway job, fail over, scale. It's a finite catalog of declared actions, never a raw shell."},
    {"Which LLMs and clients work?",
     "Anything that speaks MCP. Claude.ai and ChatGPT connect to emisar's remote MCP server over OAuth; Claude Code, Claude Desktop, Cursor, Gemini CLI, and Codex CLI use the emisar-mcp stdio bridge."},
    {"Does it need SSH or an inbound port?",
     "No. You install a lightweight runner that dials OUT to the control plane over a websocket — no inbound ports, no bastion, and no SSH key to hand an AI. The runner executes only the declared actions and streams redacted output back."},
    {"What about my secrets?",
     "The runner redacts every stdout and stderr stream on the host before it is forwarded — 20+ built-in patterns (AWS keys, JWTs, bearer tokens) plus your own per-action rules. The control plane receives only the redacted output stream — never the raw bytes."},
    {"Do I have to approve every action?",
     "No — you decide per action. Reads run automatically; you reserve approvals for the risky, mutating ones. Policy sets allow / require-approval / deny by risk tier, with per-action overrides, and the destructive verbs are deny-by-default."}
  ]

  def ai(conn, _params) do
    ai_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
          "@graph" => [
            %{
              "@type" => "SoftwareApplication",
              "name" => "emisar",
              "applicationCategory" => "DeveloperApplication",
              "operatingSystem" => "Linux, macOS",
              "url" => @base <> "/ai",
              "description" =>
                "Give your AI assistant safe, gated access to your infrastructure over MCP — read logs and metrics, investigate incidents, and act behind human approval, all audited.",
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
                Enum.map(@ai_faqs, fn {question, answer} ->
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

    render(conn, :ai,
      page_title: "Give your AI assistant safe access to your infrastructure",
      meta_description:
        "Install a runner, connect your LLM over MCP, and your AI can read logs, query metrics, and investigate incidents across your fleet — every action policy-gated, approved by a human when risky, and fully audited. No SSH, no standing access.",
      canonical_url: @base <> "/ai",
      faqs: @ai_faqs,
      pack_count: EmisarWeb.PacksRegistry.pack_count(),
      action_count: delimit_int(EmisarWeb.PacksRegistry.action_count()),
      json_ld: ai_ld
    )
  end

  # Pricing FAQ — single source of truth for the visible accordion and
  # the FAQPage JSON-LD, so Google's rich result matches the on-page text.
  @pricing_faqs [
    {"What counts as a \"runner\"?",
     "One installation of the emisar binary on one host — VM, container, or bare metal. Run as many runners as your plan allows. Human users are unlimited on Team and Enterprise."},
    {"Do you store the output of my commands?",
     "We store metadata (who, when, which action, exit code) and a configurable slice of stdout/stderr for the audit log. Output is redacted on the runner before anything is forwarded — 20+ built-in patterns plus your own per-action rules — so the control plane stores only the redacted stream, never the raw bytes."},
    {"How does billing work?",
     "Paid plans are billed per runner through Paddle, our Merchant of Record. You get monthly invoices, and Paddle handles sales tax and VAT. We never see or store full card numbers."},
    {"Can I self-host?",
     "The current product uses the hosted emisar control plane. The source-available repository includes deployable control-plane code for evaluation, but supported self-hosted and air-gapped deployments are not generally available today. Tell us if that boundary is a requirement."},
    {"Can I cancel any time?",
     "Yes. Cancel from billing settings and you drop back to Free at the end of the current billing period. Your audit data is retained per the Free retention window."},
    {"Do you support SSO and SCIM?",
     "Yes, on the Enterprise plan: OIDC single sign-on with Google Workspace, Okta, or Keycloak (or any compliant provider), plus SCIM 2.0 directory sync. Offboard someone in your IdP and emisar ends their sessions and revokes their keys automatically — no manual cleanup."},
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
      faqs: @pricing_faqs,
      json_ld: @pricing_ld
    )
  end

  # Changelog — data-driven from EmisarWeb.Changelog so the page and the
  # /changelog.xml RSS feed render from one source and never drift.
  def changelog(conn, _params) do
    render(conn, :changelog,
      page_title: "Changelog",
      meta_description:
        "Shipping notes for emisar — the control plane that gives AI agents approved infrastructure actions instead of SSH. The redesigned site, the new identity, runner releases, SSO/SCIM, approvals, and audit.",
      canonical_url: @base <> "/changelog",
      entries: EmisarWeb.Changelog.entries()
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
      {"The migration that died holding a lock", @base <> "/use-cases/postgres-ops"},
      {"The major compaction that ate the read path", @base <> "/use-cases/cassandra-ops"}
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
        "Real-shape production incidents worked end to end through emisar: a CSI driver's 33-hour data wipe, a wedged Postgres lock chain, a runaway Cassandra compaction — each investigated through declared actions, stopped behind one approval, every step audited.",
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
     "The risks of giving an AI agent SSH access to production — full blast radius, prompt injection into arbitrary commands, no gate before the action and no durable record after — and the declared-action-catalog alternative that keeps the real commands but adds a policy gate, human approval, and a tamper-evident audit."}
  ]

  def guides(conn, _params) do
    list_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
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
        },
        escape: :html_safe
      )

    guides =
      Enum.map(@guides, fn {slug, _action, title, dek, date, read_time, _desc} ->
        %{slug: slug, title: title, dek: dek, date: date, read_time: read_time}
      end)

    render(conn, :guides_index,
      page_title: "Guides — AI agents and production infrastructure",
      meta_description:
        "Practical guides on giving AI agents safe, audited access to production infrastructure — the patterns that hold, the risks of the shortcuts, and the honest trade-offs.",
      canonical_url: @base <> "/guides",
      json_ld: list_ld,
      guides: guides
    )
  end

  # Per-action JSON-LD, injected into the generated def below when present.
  @page_json_ld %{}

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

    breadcrumb_ld =
      Jason.encode!(
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" =>
            crumbs
            |> Enum.with_index(1)
            |> Enum.map(fn {{name, item}, position} ->
              %{"@type" => "ListItem", "position" => position, "name" => name, "item" => item}
            end)
        },
        escape: :html_safe
      )

    attrs = Keyword.put(attrs, :json_ld, Map.get(@page_json_ld, action, breadcrumb_ld))

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
end
