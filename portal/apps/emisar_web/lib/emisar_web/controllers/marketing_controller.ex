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
  alias EmisarWeb.{BillingIntent, UserAgent}

  plug :put_layout, html: {EmisarWeb.Layouts, :app}
  plug :assign_detected_os

  @base "https://emisar.dev"

  # path | action | template | page_title | meta_description
  @pages [
    {"/security", :security, :security, "Security & compliance",
     "emisar's security model: pre-approved actions, redacted output, searchable audit, a hash-chained runner journal, and no SSH."},
    {"/docs", :docs, :docs, "Documentation — runner setup, action packs & MCP",
     "Documentation, action pack format, security model, and integration guides for emisar."},
    {"/about", :about, :about, "About", "Why emisar exists and how we built it."},
    {"/support", :support, :support, "Support",
     "Get help with emisar setup, runners, MCP connections, billing, and account access. Contact support or report a security issue through the right channel."},
    {"/privacy", :privacy, :privacy, "Privacy Policy",
     "How emisar handles your data: what the control plane stores, how configured patterns redact runner output, what it never sees (full card numbers), where data lives, retention windows, and your export/delete rights."},
    {"/terms", :terms, :terms, "Terms of Service",
     "The terms for using emisar — the control plane that gives AI agents and humans approved infrastructure actions instead of SSH. Plans and billing, acceptable use, confidentiality, disclaimers, and account terms."},
    {"/dpa", :dpa, :dpa, "Data Processing Addendum",
     "emisar's standard Data Processing Addendum (DPA): the Article 28 terms we sign as your processor — roles, processing scope, our named subprocessors, security measures, US data residency with SCCs for EU/UK transfers, breach notification, and deletion on termination."},
    {"/refund-policy", :refund_policy, :refund_policy, "Refund Policy",
     "emisar's refund policy: Free is free; Team is billed monthly or annually via Paddle and cancellable any time; duplicate charges and billing errors are refunded in full."},
    {"/docs/mcp-reference", :mcp_reference, :mcp_reference,
     "emisar-mcp CLI and MCP API reference",
     "Use the emisar-mcp CLI from shell scripts, then inspect MCP methods, live tool schemas, mutation recovery, signing, and errors."},
    {"/docs/connect-claude-ai", :connect_claude_ai, :connect_claude_ai, "Connect Claude.ai",
     "Add emisar to Claude.ai as a custom connector over remote MCP and OAuth."},
    {"/docs/connect-chatgpt", :connect_chatgpt, :connect_chatgpt, "Connect ChatGPT",
     "Add emisar to ChatGPT through Developer mode over remote MCP and OAuth."},
    {"/docs/connect-cli-agent", :connect_cli_agent, :connect_cli_agent, "Connect a CLI agent",
     "Connect local AI clients through the emisar-mcp bridge, or call the HTTPS MCP endpoint with an emk- agent key."},
    {"/docs/connect-multiple-accounts", :connect_multiple_accounts, :connect_multiple_accounts,
     "Connect multiple accounts",
     "Work across several emisar accounts: one MCP server entry per account, the CLI's stored accounts, and one cloud connector per account."},
    {"/docs/quickstart", :quickstart, :quickstart,
     "Quickstart — install the runner + run your first action",
     "Install one Linux runner, run linux.uptime through policy, verify its audit event, and connect an LLM."},
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
     "A real incident: democratic-csi ran mkfs over a live Pure LUN on a multipath race, wiping 33 hours of VictoriaMetrics data. An agent on emisar investigated through declared actions, stopped the bleed behind one approval, and landed the durable fix as reviewable infra — a guard that refuses to trust the driver, after the obvious one-line setting turned out to be a no-op."},
    {"/use-cases/ingress-502", :ingress_502, :ingress_502,
     "Case study: a fleet-wide 502 traced through five layers — via emisar",
     "A real incident: every app behind one anycast edge threw intermittent 502 Connection refused, yet every backend was healthy. An agent on emisar traced it across five layers — FRR, Traefik, Nomad, Consul — to a Traefik OOM loop and a wedged node still advertising a dead ingress, stopped the bleed behind gated approvals, and named the durable fix: health-gate the anycast so a node withdraws itself instead of black-holing traffic."},
    {"/use-cases/cassandra-migration", :cassandra_migration, :cassandra_migration,
     "Moving Cassandra from GCP to bare metal: an AI operator's field report",
     "An AI operator explains how it authored and stress-tested a bare-metal Cassandra platform, then used emisar's bounded actions to help move 12 application jobs across 14 live keyspaces, with human decisions and corrections clearly separated."},
    {"/compare/raw-ssh-for-ai", :raw_ssh_for_ai, :raw_ssh_for_ai,
     "Why not just give the LLM SSH?",
     "Comparison: raw SSH-for-AI agents vs an emisar action pack. Both run real commands; the difference is whose recovery you're betting on."},
    {"/compare/custom-mcp-server", :custom_mcp_server, :custom_mcp_server,
     "Custom MCP server vs emisar",
     "Custom MCP server vs emisar: the arg validation, pack integrity, policy, approvals, per-user scopes, redaction, audit, and reconnect handling you'd build and own for production agent access — and emisar's real tradeoffs in return."},
    {"/compare/copy-paste-ai-ops", :copy_paste_ai_ops, :copy_paste_ai_ops,
     "Copy-pasting between an LLM and your terminal",
     "See what changes when an LLM can use a small set of approved actions instead of waiting for you to paste logs, commands, and results back and forth."},
    {"/how-it-works", :how_it_works, :how_it_works, "How emisar works",
     "How emisar works: an agent calls one declared action; the control plane checks the pack hash and policy; a human approves anything risky; the outbound-only runner re-validates and executes on your host; and every step lands in a searchable audit, mirrored to a tamper-evident hash-chained journal on your host. The five-gate path from intent to receipt."},
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
     "Policies & approvals — control what runs",
     "Control actions with risk defaults, ordered rules, human approvals, and scoped standing grants."},
    {"/docs/run-an-action", :run_an_action, :run_an_action, "Run an action",
     "Select a runner and action, enter its arguments and reason, dispatch it, and read the result."},
    {"/docs/runbooks", :runbooks, :runbooks,
     "Runbooks — build and run staged infrastructure procedures",
     "Build and publish staged procedures with typed inputs, output extraction, conditions, waits, policy, and approval."},
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
     "Configure a confidential Keycloak OIDC client with PKCE and plan for its directory-sync limit."},
    {"/docs/integrations/google-workspace", :google_workspace, :google_workspace,
     "Google Workspace SSO setup",
     "Configure Google Workspace OIDC sign-in and plan for its directory-sync limit."},
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
    {"Can the LLM run anything it wants?",
     "No. The runner accepts only actions declared in a trusted pack and allowed by its local admission rules. Undeclared commands are not part of the agent's catalog and are rejected before execution."},
    {"What can it actually do?",
     "Read and tail logs, query metrics, inspect processes, memory, disk, and containers, check your databases, and trace DNS, TLS, and connectivity — across your whole fleet. And, behind approval, act: restart a unit, stop a runaway job, fail over, scale. It's a finite catalog of declared actions, and you can add your own."},
    {"Where do approvals happen?",
     "In the web UI and your email inbox. The approver sees the actor, the arguments, the target host, and the policy rule that triggered the gate. One click to allow, one to deny."},
    {"Do I have to approve every action?",
     "No. Policy decides by risk tier, action, runner, or runner group. We all know that agents are most useful when they are unleashed so routine, bounded reads can run automatically. Risky mutations can require approval, and destructive actions can be denied. You choose where the agent keeps moving and where a person must step in."},
    {"What if my runner dies mid-run?",
     "On Linux, the runner stops the action if it exits. If the runner stays offline, emisar marks its in-flight runs as errored within minutes, so nothing appears to run forever."},
    {"Is this MCP-compatible?",
     "Yes. Claude.ai and ChatGPT connect to emisar's remote JSON-RPC MCP server through OAuth. Fifteen local clients — Claude Code, Claude Desktop, Cursor, Windsurf, Zed, Copilot CLI, Gemini CLI, Codex CLI, and more — plus almost any other MCP agent can use the emisar stdio bridge."},
    {"Can I self-host the control plane?",
     "The current product uses the hosted emisar control plane. The repository includes deployable control-plane code for evaluation, but supported self-hosted and air-gapped deployments are not generally available today. Contact us if that boundary is a requirement."},
    {"What about secrets?",
     "Runner output is redacted before leaving the host and retained in run history. The audit trail stores terminal outcome metadata, including who, when, action, runner, reason, and exit code. Patterns are declared per action; defaults catch about 20 built-in patterns."}
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
        "One governed MCP server connects any AI agent to a finite action catalog, enforced on-host with pack trust, policy gates, human approvals, and a hash-chained on-host journal.",
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
     "Runner output is redacted before leaving the host and retained in run history. The audit trail stores terminal outcome metadata, including who, when, action, runner, reason, and exit code. Redaction uses 20 built-in patterns plus your own per-action rules."},
    {"How does billing work?",
     "Paid plans are billed per runner through Paddle, our Merchant of Record. You get an invoice for each billing period, and Paddle handles sales tax and VAT. We never see or store full card numbers."},
    {"Can I self-host?",
     "The current product uses the hosted emisar control plane. The runner, MCP bridge, and packs are Apache-2.0 open source, and the repository includes deployable control-plane code (Business Source License) for evaluation — but supported self-hosted and air-gapped deployments are not generally available today. Tell us if that boundary is a requirement."},
    {"Can I cancel any time?",
     "Yes. Cancel from billing settings to stop renewal in Paddle. Paid features and limits remain available until the scheduled end of the billing period, then the account moves to Free limits."},
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
      "audit retention; #{enterprise_plan.name} is " <>
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
              "Approved infrastructure actions for AI agents — policy, approvals, searchable audit, and a hash-chained runner journal instead of SSH.",
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
       "One installation of the emisar binary on one host — VM, container, or bare metal. " <>
         "Run as many runners as your plan allows. #{member_copy}"},
      output,
      billing,
      self_host,
      cancel,
      {"Do you support SSO and SCIM?",
       "Yes. OIDC single sign-on (Okta, Entra ID, JumpCloud, Google Workspace, Keycloak, " <>
         "or any compliant provider) is on #{sso_plans}. Automatic offboarding needs SCIM " <>
         "2.0 directory sync, which is #{scim_plans}: deactivate someone in your IdP and " <>
         "emisar ends their sessions and revokes their keys without anyone touching the " <>
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
      page_title: "Use cases — real incidents emisar contained",
      meta_description:
        "Real production work handled through emisar: a live Cassandra migration from GCP to bare metal, a CSI driver's 33-hour data wipe, and a fleet-wide 502 — investigated through declared actions, with risky changes gated and every step audited.",
      canonical_url: @base <> "/use-cases",
      json_ld: json_ld
    )
  end

  # Guides — top-of-funnel long-form. Each is its own template (the body);
  # this list drives the index cards, per-guide meta + TechArticle JSON-LD,
  # and the sitemap. {slug, action/template, title, dek, date, read_time, meta}.
  @guides [
    {"how-emisar-works", :how_emisar_works, "How emisar works",
     "How do you give an AI agent access to production without worrying that it might hallucinate its way into dropping a database or taking the site down?",
     "July 2026", "9 min read",
     "See what an AI agent can actually do through emisar and what stops it doing something else, following one service restart from MCP request to runner execution and audit."},
    {"give-ai-agents-safe-production-access", :give_ai_agents_safe_production_access,
     "How to give an AI agent safe access to production",
     "Agents do their best work when nobody is watching over their shoulder. Coding agents get that freedom from a sandbox — production has no sandbox. What teams try instead, where each one cracks, and the division of labor that holds up.",
     "July 2026", "7 min read",
     "How to give an AI agent safe access to production: why SSH keeps ending in deleted-database postmortems, why an MCP server per tool becomes a maintenance and policy burden, and how one MCP with a declared action catalog lets an agent investigate production freely, ship fixes as code, and touch dangerous actions only behind human approval."},
    {"prompt-injection-for-ops-teams", :prompt_injection_for_ops_teams,
     "Prompt injection for ops teams: your logs are prompts now",
     "The moment an AI agent starts reading your production logs, everyone who can write to them can talk to it. How the trick works — and why the defense that holds isn't a smarter prompt but a shorter list of things the agent can do.",
     "July 2026", "8 min read",
     "Prompt injection for AI ops agents: how attacker-controlled text in logs, tickets, and telemetry can steer an agent with production access, why prompt-level defenses and read-only access aren't enough, and how a declared action catalog with policy, approvals, and audited denials turns a successful injection into a visible, refused request."}
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
        "Practical guides on giving AI agents safe, audited access to production infrastructure — the patterns that hold, the risks of the shortcuts, and the trade-offs.",
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

  # Every page that publishes an install command publishes it twice — a POSIX
  # shell and a PowerShell spelling — and opens on the visitor's own platform.
  # Marketing HTML is never shared-cached (only the pack registry sets a public
  # cache-control), so reading the request UA here cannot serve one visitor's
  # platform to another.
  defp assign_detected_os(conn, _opts) do
    user_agent = List.first(get_req_header(conn, "user-agent"))
    assign(conn, :detected_os, UserAgent.platform(user_agent))
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
      page_title: "Action packs registry",
      meta_description:
        "Browse the registry of action packs you can install on your emisar runner — Postgres, Cassandra, Linux core, Docker, AWS, and more. Each pack ships a typed catalog of actions an LLM can call.",
      canonical_url: @base <> "/packs",
      json_ld: json_ld
    )
  end

  def pack_detail(conn, %{"id" => id}) do
    case Catalog.get_published_pack(id) do
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
      {:ok, signup} ->
        EmisarWeb.Analytics.track_lead_captured(conn, signup.source || "footer")
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

  # A protocol-relative path ("//evil.example") is not an open redirect here —
  # Phoenix refuses it — but it refuses by RAISING, so a crafted Referer turned
  # a newsletter signup into a 500. Rejected explicitly instead.
  defp local_path(%URI{path: "//" <> _}), do: "/"
  defp local_path(%URI{path: "/" <> _ = path}), do: path
  defp local_path(_), do: "/"
end
