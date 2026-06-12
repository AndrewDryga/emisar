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
    {"/changelog", :changelog, :changelog, "Changelog",
     "Release notes for emisar — the control plane that gives AI tools approved infrastructure actions instead of SSH. Pack trust, policy gates, approvals, and audit."},
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
     "A real incident: democratic-csi reformatted a live Pure LUN on a multipath race, wiping 33 hours of VictoriaMetrics data. How an agent on emisar investigated through declared actions, stopped the bleed behind one approval, and wrote the durable fix to Terraform."},
    {"/compare/raw-ssh-for-ai", :compare_raw_ssh, :compare_raw_ssh,
     "Why not just give the LLM SSH? — honest comparison",
     "Comparison: raw SSH-for-AI agents vs an emisar action pack. Both run real commands; the difference is whose recovery you're betting on."},
    {"/compare/custom-mcp-server", :compare_custom_mcp, :compare_custom_mcp,
     "Custom MCP server vs emisar",
     "Custom MCP server vs emisar, honestly: the arg validation, pack integrity, policy, approvals, per-user scopes, redaction, audit, and reconnect handling you'd build and own for production agent access — and emisar's real tradeoffs in return."},
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
     "The runner runs a redaction pipeline on every stdout/stderr stream before forwarding. Patterns are declared per-action; sane defaults catch AWS keys, JWTs, and bearer tokens. The cloud never sees raw secrets."}
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
              "logo" => @base <> "/images/emisar-logo.svg",
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
      json_ld: org_ld
    )
  end

  # Pricing FAQ — single source of truth for the visible accordion and
  # the FAQPage JSON-LD, so Google's rich result matches the on-page text.
  @pricing_faqs [
    {"What counts as a \"runner\"?",
     "One installation of the emisar binary on one host — VM, container, or bare metal. Run as many runners as your plan allows. Human users are unlimited on Team and Enterprise."},
    {"Do you store the output of my commands?",
     "We store metadata (who, when, which action, exit code) and a configurable slice of stdout/stderr for the audit log. Secrets are redacted on the runner before anything is forwarded — 20+ built-in patterns plus your own per-action rules — so the control plane never sees raw secrets."},
    {"How does billing work?",
     "Paid plans are billed per runner through Paddle, our Merchant of Record. You get monthly invoices, and Paddle handles sales tax and VAT. We never see or store full card numbers."},
    {"Can I self-host?",
     "The current product uses the hosted emisar control plane. The source-available repository includes deployable control-plane code for evaluation, but supported self-hosted and air-gapped deployments are not generally available today. Tell us if that boundary is a requirement."},
    {"Can I cancel any time?",
     "Yes. Cancel from billing settings and you drop back to Free at the end of the current billing period. Your audit data is retained per the Free retention window."},
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
      page_title: "Pricing",
      meta_description:
        "Per runner, not per seat. Free covers 3 runners and 1 user; Team is $20 per runner per month with unlimited users and 90-day audit retention; Enterprise is custom.",
      canonical_url: @base <> "/pricing",
      faqs: @pricing_faqs,
      json_ld: @pricing_ld
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

    attrs =
      case Map.get(@page_json_ld, action) do
        nil -> attrs
        json -> Keyword.put(attrs, :json_ld, json)
      end

    template_atom = template
    attrs_literal = Macro.escape(attrs)

    def unquote(action)(conn, _params) do
      render(conn, unquote(template_atom), unquote(attrs_literal))
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
    render(conn, :packs,
      packs: EmisarWeb.PacksRegistry.list(),
      page_title: "Action packs registry",
      meta_description:
        "Browse the registry of action packs you can install on your emisar runner — Postgres, Cassandra, Linux core, Docker, AWS, and more. Each pack ships a typed catalog of actions an LLM can call.",
      canonical_url: @base <> "/packs"
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
        render(conn, :pack_detail,
          pack: pack,
          page_title: "#{pack.name} pack",
          meta_description: pack.description,
          canonical_url: @base <> "/packs/" <> pack.id
        )
    end
  end
end
