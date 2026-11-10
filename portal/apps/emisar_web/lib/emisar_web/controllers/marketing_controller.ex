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
  alias Emisar.{Billing, Catalog}
  alias EmisarWeb.{BillingIntent, MarketingComponents, UserAgent}

  plug :put_layout, html: {EmisarWeb.Layouts, :app}
  plug :assign_detected_os
  plug :assign_action_count_by_risk when action in [:how_it_works]

  @base "https://emisar.dev"

  # path | action | template | page_title | meta_description
  @pages [
    {"/security", :security, :security, "Security & compliance",
     "emisar's security model: pre-approved actions, redacted output, searchable audit, a hash-chained runner journal, and no SSH."},
    {"/docs", :docs, :docs, "Documentation — runners, action packs, CLI and MCP",
     "Documentation, action pack format, security model, and integration guides for emisar."},
    {"/about", :about, :about, "About", "Why emisar exists and how we built it."},
    {"/support", :support, :support, "Support",
     "Find documentation, Team email support, Enterprise Slack support, and help with billing, account access, or security reports."},
    {"/privacy", :privacy, :privacy, "Privacy Policy",
     "How emisar handles your data: what the control plane stores, how configured patterns redact runner output, what it never sees (full card numbers), where data lives, retention windows, and your export/delete rights."},
    {"/terms", :terms, :terms, "Terms of Service",
     "The terms for using emisar, the control plane that gives AI agents and humans approved infrastructure actions instead of SSH. Plans and billing, acceptable use, confidentiality, disclaimers, and account terms."},
    {"/dpa", :dpa, :dpa, "Data Processing Addendum",
     "emisar's standard Data Processing Addendum (DPA): the Article 28 terms we sign as your processor. Roles, processing scope, our named subprocessors, security measures, US data residency with SCCs for EU/UK transfers, breach notification, and deletion on termination."},
    {"/refund-policy", :refund_policy, :refund_policy, "Refund Policy",
     "emisar's refund policy: Free is free; Team is billed monthly or annually via Paddle and cancellable any time; duplicate charges and billing errors are refunded in full."},
    {"/docs/mcp-reference", :mcp_reference, :mcp_reference,
     "emisar CLI and MCP reference: commands, tools and outputs",
     "Use the emisar-mcp CLI from shell scripts, then inspect MCP methods, live tool schemas, mutation recovery, signing, and errors."},
    {"/docs/connect-claude-ai", :connect_claude_ai, :connect_claude_ai, "Connect Claude.ai",
     "Add emisar to Claude.ai as a custom connector over remote MCP and OAuth."},
    {"/docs/connect-chatgpt", :connect_chatgpt, :connect_chatgpt, "Connect ChatGPT",
     "Add emisar to ChatGPT through Developer mode over remote MCP and OAuth."},
    {"/docs/connect-cli-agent", :connect_cli_agent, :connect_cli_agent, "Connect a CLI agent",
     "Connect local AI clients through the emisar-mcp bridge, or call the HTTPS MCP endpoint with an emk- agent key."},
    {"/docs/connect-agent-sandboxes", :connect_agent_sandboxes, :connect_agent_sandboxes,
     "Agent sandboxes",
     "Compare co:op, Docker Sandboxes, nono, and Dev Containers, then connect a sandboxed coding agent to emisar."},
    {"/docs/connect-multiple-accounts", :connect_multiple_accounts, :connect_multiple_accounts,
     "Connect multiple accounts",
     "Work across several emisar accounts: one MCP server entry per account, the CLI's stored accounts, and one cloud connector per account."},
    {"/docs/quickstart", :quickstart, :quickstart,
     "Quickstart — install the runner + run your first action",
     "Connect a Linux host, run linux.uptime, review its result, and ask your AI agent to repeat the check through emisar."},
    {"/docs/investigate-a-service", :investigate_a_service, :investigate_a_service,
     "Investigate a service and approve a restart",
     "Run a throwaway nginx container on a dev host, let your AI agent inspect it and request a restart, then approve it and check the audit in emisar."},
    {"/docs/use-a-published-pack", :use_a_published_pack, :use_a_published_pack,
     "Use a published action pack",
     "Choose, inspect, install, configure, trust, and verify a published emisar action pack."},
    {"/docs/action-packs", :action_packs, :action_packs, "Action packs — YAML reference",
     "Reference for action pack YAML, arguments, validation, limits, side effects, and redaction."},
    {"/docs/security-model", :security_model, :security_model, "Security model",
     "Understand the emisar trust boundary, action gates, redaction, cloud audit, and hash-chained runner journal."},
    {"/docs/signed-dispatch", :signed_dispatch, :signed_dispatch,
     "Signed dispatch — a CA for runner actions, set up and rotated",
     "Require customer-signed action dispatches, then issue, rotate, and revoke the keys and certificates."},
    {"/use-cases/csi-data-loss", :csi_data_loss, :csi_data_loss,
     "Case study: a CSI driver wiped 33h of metrics — contained via emisar",
     "A real incident: democratic-csi ran mkfs over a live Pure LUN on a multipath race, wiping 33 hours of VictoriaMetrics data. An agent on emisar investigated through declared actions, stopped the bleed behind one approval, and landed the durable fix as reviewable infra: a guard that refuses to trust the driver. The obvious one-line setting turned out to be a no-op."},
    {"/use-cases/ingress-502", :ingress_502, :ingress_502,
     "Case study: a fleet-wide 502 traced through five layers — via emisar",
     "A real incident: every app behind one anycast edge threw intermittent 502 Connection refused, yet every backend was healthy. An agent on emisar traced it across five layers (FRR, Traefik, Nomad, Consul) to a Traefik OOM loop and a stuck node still advertising a dead ingress. The agent stopped the bleed behind gated approvals and named the durable fix: health-gate the anycast so a node withdraws itself instead of black-holing traffic."},
    {"/use-cases/cassandra-migration", :cassandra_migration, :cassandra_migration,
     "Cassandra migration from GCP to bare metal: AI agent field report",
     "An AI agent's Cassandra 5 migration: six GCP nodes to three bare-metal servers, 6.3 TiB of data, continuous writes, validation, and cutover."},
    {"/use-cases/website-cache-stampede", :website_cache_stampede, :website_cache_stampede,
     "How ChatGPT Sol and Terra used emisar to trace and fix a website outage",
     "How ChatGPT Sol and Terra used emisar to investigate a website outage across Nomad, Consul, metrics, and logs, then fixed a missing server cache."},
    {"/use-cases/nomad-resource-sizing", :nomad_resource_sizing, :nomad_resource_sizing,
     "How ChatGPT Sol reviewed CPU and memory across a Nomad fleet using emisar",
     "ChatGPT Sol used emisar to review a Nomad fleet. Shipped changes cut CPU reservations by 20% and memory reservations by 30%, making room for more services."},
    {"/use-cases/application-migration", :application_migration, :application_migration,
     "How ChatGPT Sol, Astra and Terra used emisar to migrate from GKE to bare metal",
     "ChatGPT Sol, Astra and Terra used emisar to build and check PostgreSQL targets during a six-service migration from GKE to Nomad."},
    {"/use-cases/cassandra-backup-costs", :cassandra_backup_costs, :cassandra_backup_costs,
     "How ChatGPT Sol used emisar to deliver $1,800/month in Cassandra backup savings",
     "ChatGPT Sol used emisar to investigate Cassandra backup costs and deliver an estimated $1,800 in monthly savings."},
    {"/compare/raw-ssh-for-ai", :raw_ssh_for_ai, :raw_ssh_for_ai,
     "Why not just give the AI agents SSH access?",
     "Compare SSH access and emisar action packs for AI agents: host permissions, command scope, approvals, audit, and when each approach fits."},
    {"/compare/custom-mcp-server", :custom_mcp_server, :custom_mcp_server,
     "Custom MCP server vs emisar",
     "Compare a custom Model Context Protocol (MCP) server with emisar for AI infrastructure access: permissions, approvals, host connections, and audit."},
    {"/compare/copy-paste-ai-ops", :copy_paste_ai_ops, :copy_paste_ai_ops,
     "Copy-pasting between an LLM and your terminal",
     "See what changes when an LLM can use a small set of approved actions instead of waiting for you to paste logs, commands, and results back and forth."},
    {"/how-it-works", :how_it_works, :how_it_works, "How emisar works",
     "Follow an infrastructure action from your AI agent through emisar policy to the runner on your host, then review the decision and result."},
    {"/trust", :trust, :trust, "Trust Center — security, infrastructure & assurance",
     "Review the controls protecting emisar: outbound-only runners, signed dispatch, private Google Cloud infrastructure, DNSSEC, hardened delivery, independent monitoring, audit evidence, DPA, subprocessors, and insurance."},
    {"/zero-trust", :zero_trust, :zero_trust, "Zero Trust for AI Agents",
     "Anthropic's Zero Trust for AI Agents framework calls for least agency, deny-by-default tools, human approval for high-risk actions, and durable audit evidence. See how emisar maps those controls between an LLM and your infrastructure. Core action controls ship on Free; SIEM export is available on Team and Enterprise."},
    {"/docs/publishing-packs", :publishing_packs, :publishing_packs,
     "Author your own action pack",
     "Write, validate, install, and trust an action pack that you maintain."},
    {"/docs/pack-registry", :pack_registry, :pack_registry, "Host your own pack registry",
     "Build a private static registry with packctl, host it over HTTPS, and install packs from immutable URLs."},
    {"/docs/policies-and-approvals", :policies_and_approvals, :policies_and_approvals,
     "AI agent access control: policies and approvals",
     "Set AI agent access control with runner scope, action policies, risk defaults, approvals, and standing grants. Learn which layer makes each decision."},
    {"/docs/run-an-action", :run_an_action, :run_an_action, "Run an action",
     "Select a runner and action, enter its arguments and reason, dispatch it, and read the result."},
    {"/docs/runbooks", :runbooks, :runbooks, "Runbook automation with emisar",
     "Automate infrastructure runbooks with declared actions, typed inputs, staged execution, approvals, and recorded results. Includes a Caddy rollout example."},
    {"/docs/authentication", :authentication, :authentication,
     "Authentication — sign-in, SSO, MFA & directory sync",
     "Choose magic links, OIDC, MFA, session controls, and SCIM provisioning for your team."},
    {"/docs/teams-and-access", :teams_and_access, :teams_and_access, "Teams, roles & access",
     "Manage roles, invitations, runner scopes, MFA, sessions, and revocable agent keys."},
    {"/docs/sso", :sso, :sso, "Single sign-on (SSO)",
     "Configure OIDC sign-in and bind each identity by issuer and subject, not email."},
    {"/docs/integrations/okta", :okta, :okta, "Okta SSO & SCIM setup",
     "Configure Okta OIDC sign-in, SCIM provisioning, lifecycle operations, and group push."},
    {"/docs/integrations/entra", :entra, :entra, "Microsoft Entra SSO & SCIM setup",
     "Configure Microsoft Entra OIDC sign-in and SCIM provisioning with stable object identifiers."},
    {"/docs/integrations/jumpcloud", :jumpcloud, :jumpcloud, "JumpCloud SSO & SCIM setup",
     "Configure one JumpCloud application for OIDC sign-in and SCIM directory provisioning."},
    {"/docs/integrations/keycloak", :keycloak, :keycloak, "Keycloak SSO setup",
     "Configure Keycloak single sign-on with a confidential OIDC client and PKCE."},
    {"/docs/integrations/google-workspace", :google_workspace, :google_workspace,
     "Google Workspace SSO setup",
     "Configure Google Workspace single sign-on for your emisar team."},
    {"/docs/scim", :scim, :scim, "Directory sync (SCIM)",
     "Provision and suspend people over SCIM, then map directory groups to roles and runner access."},
    {"/docs/runner-fleet", :runner_fleet, :runner_fleet, "Manage the runner fleet",
     "Manage runner groups, labels, enrollment keys, pack credentials, connectivity, updates, and removal."},
    {"/docs/production", :production, :production, "Go to production",
     "Plan and verify a phased runner rollout with scoped fleets, canaries, rollback, and a go-live checklist."},
    {"/docs/audit-and-siem", :audit_and_siem, :audit_and_siem, "The audit trail & SIEM export",
     "Export cloud events by polling the NDJSON export API. Verify the runner journal separately."},
    {"/docs/host-install", :host_install, :host_install, "Install the runner on a host",
     "Install the runner on Linux or macOS, configure its service, and grant only required host permissions."},
    {"/docs/containers", :containers, :containers, "Run the emisar runner in a container",
     "Run the runner in a container with explicit visibility, persistent state, and a bounded sidecar pattern."},
    {"/docs/kubernetes", :kubernetes, :kubernetes,
     "Kubernetes — one runner per node as a DaemonSet",
     "Deploy one runner per Kubernetes node and control its host access through the pod spec."},
    {"/docs/nomad", :nomad, :nomad, "Nomad — one runner per node as a system job",
     "Deploy one runner per Nomad client with a checked release, rendered config, secret, and persistent state."},
    {"/docs/autoscaling-fleets", :autoscaling_fleets, :autoscaling_fleets,
     "Autoscaling fleets — ephemeral runners on GCP, AWS, and Azure",
     "Enroll ephemeral runners on GCP, AWS, or Azure with reusable keys and fresh host identities."},
    {"/docs/runs", :runs, :runs, "Runs & run history — output, statuses, and cancellation",
     "Filter run history, read statuses and output, cancel work, and inspect grouped operations."},
    {"/docs/agents-and-keys", :agents_and_keys, :agents_and_keys, "Manage agents & keys",
     "See the agents connected to your account, and mint, rotate, or revoke the key behind one."},
    {"/docs/runner-cli", :runner_cli, :runner_cli, "Runner CLI reference",
     "Reference for runner commands, flags, local actions, packs, diagnostics, audit, signing, and lifecycle operations."},
    {"/docs/billing", :billing, :billing, "Plans & billing",
     "Understand plan limits, features, billing changes, invoices, payment failures, and audit retention."},
    {"/docs/limits", :limits, :limits, "Operational limits",
     "Review enforced limits for action output, MCP calls, runbooks, audit export, and retention."},
    {"/docs/runner-upgrades", :runner_upgrades, :runner_upgrades, "Upgrade runners",
     "Upgrade runners through a canary, verify each batch, and keep a supported rollback version."},
    {"/docs/bridge-upgrades", :bridge_upgrades, :bridge_upgrades, "Upgrade the MCP bridge",
     "Move the emisar-mcp bridge on each workstation to a new release, check it from the client, and roll back if you need to."},
    {"/docs/runner-credentials", :runner_credentials, :runner_credentials, "Runner credentials",
     "Rotate enrollment keys, understand per-runner tokens, and swap the provider credentials packs read."},
    {"/docs/credentials", :credentials, :credentials, "Rotate and revoke credentials",
     "Rotate or revoke each emisar credential with the correct overlap, reach, and recovery steps."},
    {"/docs/pack-updates", :pack_updates, :pack_updates, "Roll out and roll back action packs",
     "Update packs through a canary, trust the exact hash, use bounded batches, and keep a rollback version."},
    {"/docs/network-requirements", :network_requirements, :network_requirements,
     "Network requirements",
     "Allow the domains, ports, and protocols required by runner hosts and workstations."},
    {"/docs/troubleshooting", :troubleshooting, :troubleshooting, "Troubleshooting",
     "Start from a symptom, run the first check, follow the owned fix, and collect useful support evidence."},
    {"/docs/security-incidents", :security_incidents, :security_incidents, "Security incidents",
     "Contain leaked emisar authority, preserve evidence, replace the credential, and verify that old access fails."},
    {"/docs/architecture", :architecture, :architecture, "Architecture and failure behavior",
     "Understand each emisar component, trust boundary, stored state, delivery rule, and failure behavior."},
    {"/docs/compatibility", :compatibility, :compatibility, "Compatibility and deprecation",
     "The emisar v1 compatibility promise, frozen public contracts, supported changes, and deprecation window."}
  ]

  # Home FAQ — the single source of truth for both the visible FAQ
  # accordion (rendered from the `faqs` assign) and the FAQPage JSON-LD
  # below. Keeping them in one list is what lets Google's rich result
  # match visible content without the two drifting apart.
  @home_faqs [
    {"How do I control what the agent can run?",
     "Your agent runs actions from trusted packs under your access rules and policy. The runner checks every request again on the host."},
    {"Which infrastructure tasks can my agent handle?",
     "Your agent can read service logs, query metrics, inspect databases and containers, and carry out operations such as restarting a service. Install published packs for the software you run, or write an action for your own procedure. Your policy decides which requests are allowed."},
    {"Where do approvals happen?",
     "In the web UI and your email inbox. The approver sees who requested the action, its arguments, the target host, and the policy rule requiring approval. They can approve or deny the request."},
    {"Do I have to approve every action?",
     "No. Set rules by risk tier, action, runner, or runner group. New accounts allow low- and medium-risk actions, require approval for high-risk actions, and deny critical actions. You can change these rules or create standing grants for repeated work."},
    {"What if my runner dies mid-run?",
     "On Linux, when the runner exits, it stops the action it started. If only the connection drops, the action keeps running while the runner is alive. After a host or runner failure, inspect the target before repeating a change: the action may have run even if you never received its result."},
    {"Can an agent use emisar without an MCP client?",
     "Yes. Agents and scripts can use emisar-mcp directly from a terminal, with JSON output. CLI and MCP calls use the same server and runner checks. The key you use decides which hosts and actions you can access."},
    {"Is this MCP-compatible?",
     "Yes. Claude.ai and ChatGPT connect through remote MCP with OAuth. Fifteen local clients, including Claude Code, Claude Desktop, Cursor, Windsurf, Zed, Copilot CLI, Gemini CLI, and Codex CLI, can use the emisar stdio bridge. The bridge also works with almost any other MCP agent."},
    {"Can I self-host the control plane?",
     "Emisar's supported product uses the hosted control plane. You can run the repository code for evaluation, but we don't offer supported self-hosted or air-gapped deployments. Contact us if self-hosting is a requirement."},
    {"What about secrets?",
     "The runner masks output that matches configured patterns before sending it back. Unknown secret formats can still pass through. Run history stores exact arguments, with sensitive fields masked in console and API views; the cloud audit records decisions and outcomes."}
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
                "The best way to give your AI agents access to production. Pack trust, policy gates, approvals, searchable audit, and a hash-chained runner journal."
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
                "description" => MarketingComponents.free_plan_offer_description()
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
      page_title: "Infrastructure automation for AI agents — CLI and MCP",
      meta_description:
        "Let AI agents automate infrastructure tasks through CLI or MCP. Set action permissions, run routine checks, and require approval for risky changes.",
      canonical_url: @base <> "/",
      faqs: @home_faqs,
      pack_count: Catalog.published_pack_count(),
      action_count: delimit_int(Catalog.published_action_count()),
      json_ld: org_ld
    )
  end

  # Static pricing FAQ answers. The two answers that name plan membership are
  # built from Billing in pricing_faqs/1 instead.
  @pricing_faqs [
    {"Do you store the output of my commands?",
     "Yes. Run history stores command output after the runner filters it on the host using 20 built-in redaction patterns and your per-action rules. The audit trail records who ran the action, when, on which runner, their reason, and the final exit code."},
    {"How does billing work?",
     "Paid plans are billed per runner through Paddle, our Merchant of Record. You get an invoice for each billing period, and Paddle handles sales tax and VAT. We never see or store full card numbers."},
    {"Can I self-host?",
     "The supported product uses emisar's hosted control plane. The runner, MCP bridge, and packs are open source under Apache-2.0. You can run the control-plane code under the Business Source License for evaluation, but supported self-hosted and air-gapped deployments are not generally available. Contact us if you need self-hosting."},
    {"Can I cancel any time?",
     "Yes. Cancel in billing settings to stop renewal through Paddle. Your paid features and limits remain available until the end of the billing period, then your account returns to Free limits."},
    {"Do you offer startup discounts?",
     "Yes. Email sales@emisar.dev with your YC or pre-seed letter and we'll take it from there."}
  ]

  @pricing_plan_order ~w(free team enterprise)

  def pricing(conn, _params) do
    plans = Billing.plans()
    free_plan = Map.fetch!(plans, "free")
    team_plan = Map.fetch!(plans, "team")
    enterprise_plan = Map.fetch!(plans, "enterprise")
    faqs = pricing_faqs(plans)

    team_intents = %{
      month: BillingIntent.sign("team", :month),
      year: BillingIntent.sign("team", :year)
    }

    render(conn, :pricing,
      page_title: "Pricing — per runner, not per seat",
      meta_description: pricing_meta_description(free_plan, team_plan, enterprise_plan),
      canonical_url: @base <> "/pricing",
      og_image: @base <> "/images/og/og-pricing.png",
      faqs: faqs,
      free_plan: free_plan,
      team_plan: team_plan,
      enterprise_plan: enterprise_plan,
      comparison: pricing_comparison(plans),
      free_price: dollars(free_plan.monthly_price_cents),
      team_monthly_price: dollars(team_plan.monthly_price_cents),
      team_annual_price: dollars(team_plan.annual_price_cents),
      team_annual_savings: Billing.annual_savings_label(team_plan),
      team_intent_paths: %{
        month: ~p"/start/team/#{team_intents.month}",
        year: ~p"/start/team/#{team_intents.year}"
      },
      enterprise_price: price_label(enterprise_plan.monthly_price_cents),
      json_ld: pricing_ld(free_plan, team_plan, faqs)
    )
  end

  defp pricing_meta_description(free_plan, team_plan, enterprise_plan) do
    "Per runner, not per seat. #{free_plan.name} covers #{free_plan.runners_limit} runners " <>
      "and #{member_limit(free_plan.members_limit)}; #{team_plan.name} is " <>
      "$#{dollars(team_plan.monthly_price_cents)} per runner per month with " <>
      "#{member_limit(team_plan.members_limit)} and #{team_plan.audit_retention_days}-day " <>
      "audit logs; #{enterprise_plan.name} is " <>
      "#{price_description(enterprise_plan.monthly_price_cents)}."
  end

  defp pricing_ld(free_plan, team_plan, faqs) do
    Jason.encode!(
      %{
        "@context" => "https://schema.org",
        "@graph" => [
          %{
            "@type" => "Product",
            "name" => "emisar",
            "description" =>
              "Approved infrastructure actions for AI agents, with policy, approvals, searchable audit, and a hash-chained runner journal instead of SSH.",
            "brand" => %{"@type" => "Brand", "name" => "emisar"},
            "offers" => [
              %{
                "@type" => "Offer",
                "name" => free_plan.name,
                "price" => dollars(free_plan.monthly_price_cents),
                "priceCurrency" => "USD",
                "description" =>
                  "Up to #{free_plan.runners_limit} runners, " <>
                    "#{member_limit(free_plan.members_limit)}, " <>
                    "#{free_plan.audit_retention_days}-day audit retention"
              },
              %{
                "@type" => "Offer",
                "name" => team_plan.name,
                "price" => dollars(team_plan.monthly_price_cents),
                "priceCurrency" => "USD",
                "description" =>
                  "Per runner / month. #{String.capitalize(member_limit(team_plan.members_limit))}, " <>
                    "#{team_plan.audit_retention_days}-day audit retention"
              }
            ]
          },
          %{
            "@type" => "FAQPage",
            "mainEntity" =>
              Enum.map(faqs, fn {question, answer} ->
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
  end

  defp pricing_faqs(plans) do
    team_plan = Map.fetch!(plans, "team")
    enterprise_plan = Map.fetch!(plans, "enterprise")
    [output, billing, self_host, cancel, startup_discounts] = @pricing_faqs
    sso_plans = plans_with_feature(plans, :sso)
    scim_plans = plans_with_feature(plans, :scim)

    member_copy =
      if team_plan.members_limit == enterprise_plan.members_limit do
        "Human users are #{member_availability(team_plan.members_limit)} on " <>
          "#{team_plan.name} and #{enterprise_plan.name}."
      else
        "#{team_plan.name} includes #{member_limit(team_plan.members_limit)}; " <>
          "#{enterprise_plan.name} includes #{member_limit(enterprise_plan.members_limit)}."
      end

    [
      {"What counts as a \"runner\"?",
       "One installation of the emisar binary on one host (VM, container, or bare metal). " <>
         "Run as many runners as your plan allows. #{member_copy}"},
      output,
      billing,
      self_host,
      cancel,
      {"Do you support SSO and SCIM?",
       "Yes. OIDC single sign-on (Okta, Entra ID, JumpCloud, Google Workspace, Keycloak, " <>
         "or any compliant provider) is on #{sso_plans}. Automatic offboarding needs SCIM " <>
         "2.0 directory sync, which is on #{scim_plans}. Deactivate someone in your IdP and " <>
         "emisar ends their browser access to that workspace and revokes keys issued from " <>
         "that membership without anyone touching the " <>
         "console. With OIDC alone they can't sign in again, but a live session or an " <>
         "existing API key keeps working until you suspend them here."},
      startup_discounts
    ]
  end

  defp pricing_comparison(plans) do
    Map.new(@pricing_plan_order, fn plan_id ->
      plan = Map.fetch!(plans, plan_id)

      {plan_id,
       %{
         audit_export: plan_supports_feature?(plans, plan_id, :audit_export),
         sso: plan_supports_feature?(plans, plan_id, :sso),
         scim: plan_supports_feature?(plans, plan_id, :scim),
         support: plan_feature(plan, :support),
         deployment: plan_feature(plan, :deployment_planning)
       }}
    end)
  end

  defp plans_with_feature(plans, feature) do
    @pricing_plan_order
    |> Enum.filter(&plan_supports_feature?(plans, &1, feature))
    |> Enum.map(&(plans |> Map.fetch!(&1) |> Map.fetch!(:name)))
    |> join_plan_names()
  end

  defp plan_supports_feature?(plans, plan_id, feature) do
    plan = Map.fetch!(plans, plan_id)
    team_plan = Map.fetch!(plans, "team")

    Keyword.has_key?(plan.features, feature) or
      (Keyword.has_key?(plan.features, :team) and Keyword.has_key?(team_plan.features, feature))
  end

  defp plan_feature(plan, feature), do: Keyword.get(plan.features, feature)

  defp join_plan_names([]), do: "no current plan"
  defp join_plan_names([name]), do: name
  defp join_plan_names([first, second]), do: "#{first} and #{second}"

  defp join_plan_names(names) do
    {last, initial} = List.pop_at(names, -1)
    "#{Enum.join(initial, ", ")}, and #{last}"
  end

  defp member_limit(:unlimited), do: "unlimited users"
  defp member_limit(1), do: "1 user"
  defp member_limit(limit), do: "#{limit} users"

  defp member_availability(:unlimited), do: "unlimited"
  defp member_availability(limit), do: "limited to #{member_limit(limit)}"

  defp price_label(nil), do: "Custom"
  defp price_label(cents), do: "$#{dollars(cents)}"

  defp price_description(nil), do: "custom"
  defp price_description(cents), do: "$#{dollars(cents)} per runner per month"

  defp dollars(cents) when is_integer(cents) do
    major = div(cents, 100)

    case rem(cents, 100) do
      0 -> Integer.to_string(major)
      minor -> "#{major}.#{minor |> Integer.to_string() |> String.pad_leading(2, "0")}"
    end
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
      page_title: "emisar changelog: runner, CLI and action-pack releases",
      meta_description:
        "emisar release notes for the runner, direct CLI, MCP tools, action packs, and access controls. Follow each release and find current setup documentation.",
      canonical_url: @base <> "/changelog",
      entries: EmisarWeb.Changelog.entries(),
      json_ld: json_ld
    )
  end

  # GET /changelog.xml — RSS 2.0 from the same EmisarWeb.Changelog source.
  # The body is XML served as application/rss+xml, built from the compiled
  # changelog with every text field passed through xml_escape/1.
  # sobelow_skip ["XSS.SendResp"]
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
            <description>#{xml_escape(EmisarWeb.Changelog.full_text(entry))}</description>
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
      {"How ChatGPT Sol and Terra used emisar to trace and fix a website outage",
       @base <> "/use-cases/website-cache-stampede"},
      {"How ChatGPT Sol reviewed CPU and memory across a Nomad fleet using emisar",
       @base <> "/use-cases/nomad-resource-sizing"},
      {"How ChatGPT Sol, Astra and Terra used emisar to migrate from GKE to bare metal",
       @base <> "/use-cases/application-migration"},
      {"How ChatGPT Sol used emisar to deliver $1,800/month in Cassandra backup savings",
       @base <> "/use-cases/cassandra-backup-costs"},
      {"How ChatGPT Sol helped move Cassandra from GCP to bare metal",
       @base <> "/use-cases/cassandra-migration"},
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
      page_title: "Use cases — production work with emisar",
      meta_description:
        "See how AI agents used emisar to migrate applications, reduce infrastructure costs, and resolve production incidents.",
      canonical_url: @base <> "/use-cases",
      json_ld: json_ld
    )
  end

  # Guides — top-of-funnel long-form. Each is its own template (the body);
  # this list drives the index cards, per-guide meta + TechArticle JSON-LD,
  # and the sitemap. {slug, action/template, title, dek, date, read_time, meta}.
  @guides [
    {"cli-vs-mcp-for-infrastructure-agents", :cli_vs_mcp_for_infrastructure_agents,
     "CLI vs MCP: why CLI tools work so well for AI agents",
     "Your agent can write scripts. Let it. Why CLI tools compose well, keep intermediate data out of context, and make room for useful work.",
     "November 10, 2026", "6 min read",
     "CLI vs MCP for AI agents: how scripts, pipes, and on-demand tool discovery can save tokens, with examples and a clear role for MCP."},
    {"how-emisar-works", :how_emisar_works, "How emisar works: the technical guide",
     "Follow a service restart from a CLI or MCP request through policy, runner checks, execution, and audit.",
     "Updated November 10, 2026", "7 min read",
     "See how emisar checks infrastructure actions from CLI and MCP clients: pack trust, access control, execution, result recovery, and audit records."},
    {"give-ai-agents-safe-production-access", :give_ai_agents_safe_production_access,
     "How to give an AI agent safe access to production",
     "From copy-pasting logs to SSH and MCP: how to let an agent work on production without handing it the keys to everything.",
     "Updated November 10, 2026", "7 min read",
     "AI agent security in production: compare SSH and MCP, control permissions, and let agents investigate while fixes go through code review."},
    {"prompt-injection-for-ops-teams", :prompt_injection_for_ops_teams,
     "Prompt injection for ops teams: your logs are prompts now",
     "The moment an AI agent starts reading your production logs, everyone who can write to them can talk to it. Here is how the trick works, and why the defense that holds is a shorter list of things the agent can do, not a smarter prompt.",
     "Updated November 2, 2026", "8 min read",
     "How prompt injection in logs steers AI agents, why prompt rules and read-only access fall short for ops teams, and how bounded actions limit the damage."}
  ]
  @guide_summaries Enum.map(@guides, fn {slug, _action, title, dek, date, read_time, _desc} ->
                     %{slug: slug, title: title, dek: dek, date: date, read_time: read_time}
                   end)

  @doc "Internal — the sitemap derives per-guide URLs from `@guides` so they can't drift."
  def guide_paths do
    Enum.map(@guides, fn {slug, _action, _title, _dek, _date, _read_time, _desc} ->
      "/guides/" <> slug
    end)
  end

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

    render(conn, :guides,
      page_title: "Guides — AI agents and production infrastructure",
      meta_description:
        "Practical guides on giving AI agents safe, audited access to production infrastructure: the patterns that hold, the risks of the shortcuts, and the trade-offs.",
      canonical_url: @base <> "/guides",
      og_image: @base <> "/images/og/og-guides.png",
      json_ld: list_ld,
      guides: @guide_summaries
    )
  end

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
    # (for /docs/*) → this page — so search results can show the hierarchy.
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
                    "description" => MarketingComponents.free_plan_offer_description()
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

    attrs = Keyword.put(attrs, :json_ld, default_ld)

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

  # Every page that publishes an install command publishes it twice — a POSIX
  # shell and a PowerShell spelling — and opens on the visitor's own platform.
  # Marketing HTML is never shared-cached (only the pack registry sets a public
  # cache-control), so reading the request UA here cannot serve one visitor's
  # platform to another.
  defp assign_detected_os(conn, _opts) do
    user_agent = List.first(get_req_header(conn, "user-agent"))
    assign(conn, :detected_os, UserAgent.platform(user_agent))
  end

  # How it works draws the default policy as a line of the four risk tiers, each
  # with its live action count from the published catalog (like the home page's
  # total), so the numbers never go stale. A tier with no actions shows 0.
  defp assign_action_count_by_risk(conn, _opts) do
    counts = Catalog.published_action_count_by_risk()

    assign(
      conn,
      :action_count_by_risk,
      Map.new(~w(low medium high critical), &{&1, delimit_int(Map.get(counts, &1, 0))})
    )
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

      {^slug, action, title, dek, date, read_time, description} ->
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
          guide_meta: %{title: title, dek: dek, date: date, read_time: read_time},
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
  # `Emisar.Catalog` owns the published catalog data; this
  # controller only renders it, grouped for display by
  # `EmisarWeb.PacksRegistry`.

  def packs(conn, _params) do
    packs = Catalog.list_published_packs()

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
      grouped: EmisarWeb.PacksRegistry.grouped(packs),
      pack_count: Catalog.published_pack_count(),
      action_count: delimit_int(Catalog.published_action_count()),
      page_title: "Infrastructure action packs for AI agents",
      meta_description:
        "Connect AI agents to PostgreSQL, Cassandra, Linux, Docker, AWS, and more through CLI or MCP. Browse action packs, setup requirements, and examples.",
      canonical_url: @base <> "/packs",
      json_ld: json_ld
    )
  end

  # Editorial entry points sit above the published pack's full action contract.
  @pack_overviews %{
    "cassandra" => %{
      title: "Cassandra AI access through CLI and MCP",
      heading: "Give AI agents access to Cassandra operations",
      intro:
        "Connect your AI agent to Cassandra through emisar’s CLI or MCP server. Check cluster health, investigate compaction, and request repairs. Choose which actions can run automatically and which need your approval."
    },
    "postgres" => %{
      title: "PostgreSQL AI access through CLI and MCP",
      heading: "Give AI agents access to PostgreSQL operations",
      intro:
        "Connect your AI agent to PostgreSQL through emisar’s CLI or MCP server. Find blocked queries, check replication lag, and inspect query plans. Choose which actions can run automatically and which need your approval."
    },
    "kubernetes" => %{
      title: "Kubernetes AI agent access through CLI and MCP",
      heading: "Give AI agents access to Kubernetes operations",
      intro:
        "Connect your AI agent to Kubernetes through emisar’s CLI or MCP server. Investigate unhealthy pods, check rollouts, and request restarts or rollbacks. Both emisar policy and Kubernetes permissions control what it can do."
    }
  }

  @pack_summaries %{
    "airflow" =>
      "Inspect Apache Airflow health, DAG runs, task logs, and import errors. Pause DAGs, trigger runs, and review actions for incident response.",
    "apache-httpd" =>
      "Inspect Apache HTTP Server status, configuration, virtual hosts, and logs. Give AI agents actions for syntax checks and graceful reloads.",
    "artifactory" =>
      "Inspect JFrog Artifactory health, storage use, repositories, and artifact download statistics with read-only actions for AI agents.",
    "aws-cloudwatch" =>
      "Read AWS CloudWatch metrics, alarms, log groups, and log queries through emisar CLI or MCP. Review credentials, action arguments, and installation.",
    "aws-cost" =>
      "Track AWS costs by service and account with read-only Cost Explorer actions. Check spending history and forecasts through CLI or MCP.",
    "aws-iam" =>
      "Inspect AWS IAM users, roles, policies, and access keys. Use policy-controlled actions to disable compromised keys or detach a user policy.",
    "aws-rds" =>
      "Diagnose AWS RDS instances and clusters with read-only actions for snapshots, parameter groups, maintenance, and recent events.",
    "aws-s3" =>
      "Inspect Amazon S3 buckets, access policies, encryption, replication, and object metadata. Read-only actions exclude object contents.",
    "betterstack" =>
      "Check Better Stack monitors, incidents, heartbeats, and uptime metrics. Let AI agents investigate outages and request monitor or incident changes.",
    "bind" =>
      "Check BIND DNS status, validate zones, and test local resolution. Review actions for cache flushes, reloads, and zone freeze or thaw.",
    "bonding" =>
      "Check Linux network bonding and LACP status. Inspect bond modes, member links, and partner state with read-only actions for AI agents.",
    "bunnycdn" =>
      "Manage bunny.net CDN Pull Zones through emisar. Inspect traffic and origin errors, purge caches, and review hostname and access-control actions.",
    "caddy" =>
      "Inspect Caddy upstream health, access logs, and runtime metrics. Validate a configuration before requesting a live reload.",
    "cassandra" =>
      "Give AI agents Cassandra access through CLI or MCP. Check cluster health, streaming, and compaction. Review repair actions, inputs, risks, and setup.",
    "clickhouse" =>
      "Investigate ClickHouse slow queries, replication queues, merges, and server errors. Review query cancellation and other operational actions.",
    "cloud-init" =>
      "Diagnose cloud-init boot failures with status, module timings, configuration, and logs. Review actions for rerunning modules or initialization.",
    "cloudflare" =>
      "Give AI agents Cloudflare tools to inspect DNS and tunnels, purge selected cache entries, and review or roll back Pages deployments.",
    "cockroach" =>
      "Check CockroachDB nodes, ranges, locks, and running queries. Inspect jobs and review actions to cancel work or decommission a node.",
    "consul" =>
      "Inspect Consul services, health checks, Raft state, and service mesh settings. Review actions for maintenance, snapshots, and cluster recovery.",
    "databricks" =>
      "Query Databricks data, browse Unity Catalog, and inspect failed jobs. Use separate actions to start warehouses, run jobs, or restart clusters.",
    "debian" =>
      "Inspect Debian and Ubuntu packages and patching status. Install or remove a named package through declared actions with policy checks.",
    "debugging" =>
      "Investigate Linux CPU, memory, disk, process, and network problems. Review diagnostics and actions for process signals and kernel settings.",
    "dell-idrac" =>
      "Dell iDRAC Redfish actions for hardware health, storage, firmware, logs, and controlled power operations. Review credentials, arguments, and limits.",
    "dell-ipmi" =>
      "Dell IPMI actions for BMC sensors, event logs, inventory, and power state, plus controlled power and boot operations. Inspect setup and risk tiers.",
    "dnf-rpm" =>
      "Inspect RPM packages and DNF updates on RHEL, Fedora, AlmaLinux, and Rocky Linux. Review actions to install, upgrade, or remove packages.",
    "docker" =>
      "Inspect Docker containers and Compose services through CLI or MCP. Read status and review actions to restart, stop, or remove unused resources.",
    "elasticsearch" =>
      "Inspect Elasticsearch and OpenSearch clusters and indexes. Review actions for cache clearing, force merges, flushes, and closing an index.",
    "elixir-beam" =>
      "Diagnose Elixir and Erlang BEAM applications: inspect memory, schedulers, supervisors, and mailboxes, or trace calls on a host or in Docker.",
    "emqx" =>
      "Check EMQX MQTT broker health, client sessions, subscriptions, and alarms. Review actions for client bans, listener restarts, and rule changes.",
    "envoy" =>
      "Inspect Envoy clusters, listeners, certificates, and runtime configuration. Review actions to drain traffic or change health and logging settings.",
    "fail2ban" =>
      "Inspect fail2ban jails, banned IPs, and logs. Let AI agents request bans, remove false positives, or reload filters under your policy.",
    "firewall" =>
      "Inspect iptables, nftables, connection tracking, and traffic control. Review inputs and risks for IP blocks and chain flushes.",
    "frr" =>
      "Inspect FRRouting BGP neighbors, BFD peers, routes, and interfaces. Request a policy-controlled BGP drain and restore advertisements afterward.",
    "fs-search" =>
      "Give AI agents read-only filesystem tools to find files, search text, inspect file metadata, and check disk use, hashes, or recent changes.",
    "gcp-billing" =>
      "Analyze Google Cloud costs by service, project, and SKU from BigQuery billing exports. Check daily spending, budgets, and export freshness.",
    "gcp-certificates" =>
      "Check Google Cloud SSL and Certificate Manager certificates, maps, and DNS authorizations with read-only actions that exclude private keys.",
    "gcp-cloudsql" =>
      "Diagnose Google Cloud SQL with instance, backup, operation, and Query Insights checks. Review separate actions for restart and failover.",
    "gcp-compute" =>
      "Inspect Google Cloud VMs and managed instance groups. Review actions to start, stop, or reset instances and resize groups through CLI or MCP.",
    "gcp-dataproc" =>
      "Investigate Google Cloud Dataproc clusters, jobs, failures, and driver logs. Review actions to start, stop, resize, or cancel existing work.",
    "gcp-dns" =>
      "Inspect Google Cloud DNS zones, policies, and record sets. Review actions to upsert or delete one exact DNS record set.",
    "gcp-iam" =>
      "Inspect Google Cloud IAM service-account policies and workload identity providers. Discover accessible projects with read-only actions.",
    "gcp-load-balancing" =>
      "Inspect Google Cloud load balancer topology, backend health, forwarding rules, and network endpoint groups through read-only diagnostic actions.",
    "gcp-monitoring" =>
      "Query Google Cloud logs and metrics, check Interconnect use, and inspect alert policies. Enable or disable a selected alert policy.",
    "gcp-networking" =>
      "Diagnose Google Cloud VPCs, subnets, firewall rules, routes, NAT, VPN, and Interconnect. Read-only actions show fixed network status fields.",
    "gcp-secret-manager" =>
      "Check the state and lifecycle timestamps of one Google Secret Manager version. Read-only metadata access never retrieves the secret payload.",
    "gcp-storage" =>
      "Inspect Google Cloud Storage buckets, access policies, object listings, and object metadata with read-only actions. No object body reads.",
    "git-local" =>
      "Inspect a Git checkout on a runner host: working-tree status, diffs, commit history, branches, and blame. All actions are read-only.",
    "github-cli" =>
      "Give AI agents GitHub actions for pull requests, issues, checks, and workflow runs. Review controls for merging PRs and rerunning workflows.",
    "grafana" =>
      "Give AI agents read-only Grafana tools to check data source health, find dashboards, inspect alert state, and review server settings.",
    "haproxy" =>
      "Inspect HAProxy statistics, frontends, backends, and sessions through its admin socket. Review actions to enable or disable backend servers.",
    "hcp-terraform" =>
      "Review HCP Terraform plan summaries and failed-run logs. Request speculative plans, retries, or policy-controlled run approval.",
    "iperf3" =>
      "Measure TCP bandwidth, UDP jitter, and packet loss between hosts with iperf3. Run a one-shot server, then test from another runner.",
    "iscsi" =>
      "Inspect Linux iSCSI sessions, target nodes, connections, and initiator interfaces. Read negotiated parameters without changing storage access.",
    "java-jvm" =>
      "Inspect JVM threads, memory, garbage collection, and flight recordings. Run diagnostics as the JVM process owner through emisar.",
    "kafka" =>
      "Check Kafka consumer lag, topics, and broker configuration. Review actions for offset resets, retention changes, and leader elections.",
    "kubernetes" =>
      "Give AI agents Kubernetes access through CLI or MCP. Check workloads, events, and logs. Review action inputs, risks, permissions, and setup.",
    "linux-core" =>
      "Give AI agents Linux access through CLI or MCP. Check host health and systemd services, then review the actions for service changes.",
    "medusa" =>
      "Cassandra Medusa actions for backup status, verification, retention, and node backup or restore. Inspect action risks and required host setup.",
    "memcached" =>
      "Check Memcached statistics, slab usage, and item counts through CLI or MCP. Review the separate critical-risk action for flushing the cache.",
    "minio" =>
      "Inspect MinIO clusters, buckets, and users through emisar. Review actions for bucket healing, user access changes, and cluster service restarts.",
    "mongodb" =>
      "Inspect MongoDB replication lag, slow queries, and collection statistics. Review actions to stop operations, compact collections, or drop indexes.",
    "multipath" =>
      "Inspect Linux device-mapper multipath topology, configuration, and live path status. Read-only actions help investigate storage connectivity.",
    "mysql" =>
      "Diagnose MySQL and MariaDB with read-only actions. Review controls for killing queries, flushing logs, and analyzing tables through CLI or MCP.",
    "nats" =>
      "Inspect NATS JetStream streams and consumers. Review actions for retention limits, consumer pauses, leadership changes, and deletion.",
    "network-tls" =>
      "Diagnose DNS, network reachability, TLS certificates, and HTTP timing with read-only actions. Check connectivity and certificate expiry.",
    "nfs" =>
      "Inspect NFS exports, mounted shares, RPC state, and client connections. Review actions to reload exports or remove access for one client.",
    "nginx" =>
      "Investigate Nginx errors, slow requests, connections, and TLS certificates. Check configuration before requesting a reload.",
    "nic" =>
      "Inspect Linux NIC drivers, firmware, link settings, hardware counters, and offload features with read-only ethtool actions for AI agents.",
    "nodejs-pm2" =>
      "Inspect Node.js applications managed by PM2, including processes, app details, and logs. Review actions for restarts, reloads, stops, and scaling.",
    "nomad" =>
      "Give AI agents Nomad access through CLI or MCP. Check jobs, deployments, allocations, and logs. Review the actions for changes and setup.",
    "oidc-jwks" =>
      "Check OpenID Connect discovery and JWKS endpoints, compare signing-key IDs, and inspect JWT headers with read-only diagnostics.",
    "pfsense" =>
      "Inspect pfSense firewall rules, gateways, VPN status, and logs through its REST API. Review actions to apply filters, flush states, or restart services.",
    "php-fpm" =>
      "Inspect PHP-FPM pool status, error and slow logs, OPcache, PHP modules, and Composer metadata with read-only actions for application diagnostics.",
    "podman" =>
      "Inspect Podman containers, logs, resource use, and images. Review separate actions to restart, stop, or kill containers and prune storage.",
    "postfix" =>
      "Inspect Postfix queues, configuration, and logs. Review actions to hold or delete individual messages, requeue mail, or flush the deferred queue.",
    "postgres" =>
      "Give AI agents PostgreSQL access through CLI or MCP. Check sessions, locks, and replication, then review the actions for database changes.",
    "process-forensics" =>
      "Investigate stuck or slow Linux processes with memory maps, thread state, strace, and gdb. Tracing is read-only but can slow the target process.",
    "prometheus" =>
      "Query Prometheus metrics, inspect targets and alerts, and check storage statistics. Review actions for reloads, snapshots, and series deletion.",
    "pure-flasharray" =>
      "Inspect Pure Storage FlashArray capacity, performance, hardware health, volumes, and replication through read-only Purity REST API actions.",
    "python-app" =>
      "Inspect Python virtual environments, installed packages, dependency conflicts, and import paths. Read-only actions leave the deployment unchanged.",
    "rabbitmq" =>
      "Inspect RabbitMQ cluster health, queues, consumers, and connections. Review actions to purge queues, sync queues, or close connections.",
    "redis" =>
      "Investigate Redis memory, latency, keyspace, and replication. Review cluster and Sentinel actions, persistence controls, and destructive operations.",
    "rke2" =>
      "Inspect RKE2 server hosts: embedded etcd health, snapshot history, certificate expiry, and containerd state beyond the Kubernetes API.",
    "sentry" =>
      "Triage Sentry issues, read error events, and inspect releases. Assign issues, change their status, or enable and disable project ingest keys.",
    "shell" =>
      "Run arbitrary shell scripts on staging hosts only. This critical-risk pack is denied by default. Never install it on production runners.",
    "showcase" =>
      "Explore emisar action-pack examples for argument types, validation, parsers, limits, and redaction. A reference for authors, not a production pack.",
    "snmp" =>
      "Read network device health, interfaces, BGP peers, and OSPF neighbors over SNMP. Query one OID or inspect a bounded subtree.",
    "spark" =>
      "Inspect Apache Spark jobs, stages, executors, and SQL executions. Diagnose live or completed applications and review controls to stop runaway work.",
    "ssl-local" =>
      "Inspect local SSL/TLS certificates, certificate chains, key matches, and PKCS#12 files with read-only actions for diagnosing certificate problems.",
    "supertokens" =>
      "Inspect SuperTokens health, tenants, users, and sessions. Review actions to revoke sessions, change user roles, or delete a user.",
    "symbolicator" =>
      "Debug native crashes with Symbolicator using stack traces, minidumps, or Apple crash reports. Check service health and preview cache cleanup.",
    "systemd-deep" =>
      "Inspect failed systemd units, timers, cgroups, journals, and boot timing. Review actions for daemon reloads, masking, signals, and resetting failures.",
    "tailscale" =>
      "Check Tailscale peers, connectivity, DNS, routes, and exit nodes with read-only actions through CLI or MCP. See setup, inputs, and limits.",
    "terraform-readonly" =>
      "Let AI agents inspect Terraform or OpenTofu configuration, plans, and state with read-only CLI actions. Keep applies in your deployment workflow.",
    "time-sync" =>
      "Diagnose Linux clock drift with Chrony and NTPsec checks. Inspect time sources and review actions to correct time or enable and disable NTP.",
    "traefik" =>
      "Diagnose Traefik routers, services, backend health, metrics, and certificate state. Use read-only readiness checks before routing traffic to a host.",
    "typesense" =>
      "Check Typesense health, request statistics, and collection schemas. Inspect node state, metrics, and slow requests with read-only actions.",
    "vault" =>
      "Inspect HashiCorp Vault health, seal state, mounts, tokens, and leases. Review actions to revoke leases, step down a leader, or seal Vault.",
    "vector" =>
      "Inspect Vector pipelines, validate configuration, view topology, and sample events. Read health and component counters without changing the pipeline.",
    "victorialogs" =>
      "Query VictoriaLogs with LogsQL to find log entries, chart hits, aggregate statistics, and discover fields within a bounded time window.",
    "victoriametrics" =>
      "Query VictoriaMetrics with PromQL or MetricsQL through CLI or MCP. Discover series and labels, inspect cardinality, and check active queries.",
    "wireguard" =>
      "Inspect WireGuard peers, handshakes, and traffic counters. Review actions to bring interfaces up or down and remove a peer from a live interface.",
    "zfs" =>
      "Inspect ZFS pools, datasets, snapshots, and ARC statistics. Review actions to scrub pools, clear errors, create snapshots, or roll back a dataset.",
    "zookeeper" =>
      "Inspect ZooKeeper cluster health, watches, and sessions with read-only actions. Review connection setup and the four-letter command whitelist.",
    "zot" =>
      "Inspect zot OCI registry repositories, tags, manifests, health, and metrics. Read repository sizes and vulnerability summaries without changing images."
  }

  def pack_detail(conn, %{"id" => id}) do
    case Catalog.get_published_pack(id) do
      nil ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> put_view(html: EmisarWeb.ErrorHTML)
        |> render(:"404")

      pack ->
        url = @base <> "/packs/" <> pack.id
        name = String.replace(pack.name, ~r/\s+pack$/i, "")
        summary = Map.get(@pack_summaries, pack.id, pack.description)
        overview = Map.get(@pack_overviews, pack.id)

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
                  "name" => "#{name} action pack",
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
          pack_overview: overview,
          page_title: if(overview, do: overview.title, else: "#{name} pack"),
          meta_description: summary,
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
      {:ok, signup} ->
        EmisarWeb.Analytics.track_lead_captured(conn, signup.source || "footer")
        thank_subscriber(conn)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "That doesn't look like a valid email. Please try again.")
        |> redirect(to: return_path(conn))
    end
  end

  defp thank_subscriber(conn) do
    conn
    |> put_flash(
      :info,
      "You're subscribed. We'll email you when we ship something major."
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

  # A protocol-relative path ("//evil.example") is not an open redirect here —
  # Phoenix refuses it — but it refuses by RAISING, so a crafted Referer turned
  # a newsletter signup into a 500. Rejected explicitly instead.
  defp local_path(%URI{path: "//" <> _}), do: "/"
  defp local_path(%URI{path: "/" <> _ = path}), do: path
  defp local_path(_), do: "/"
end
