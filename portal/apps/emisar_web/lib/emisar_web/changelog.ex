defmodule EmisarWeb.Changelog do
  @moduledoc """
  Single source for the product changelog — rendered on `/changelog` and as
  the `/changelog.xml` RSS feed, so the two never drift. Each entry is a real
  product release and carries its git tag (`vMAJOR.MINOR.0`); the tag points at
  the last commit of that version's window, so the commit history, the tags, and
  this changelog all line up. Newest first.
  """

  @base "https://emisar.dev"

  @entries [
    %{
      date: ~D[2026-06-25],
      slug: "analytics-and-console-craft",
      title: "Product analytics and the console craft pass",
      tag: "v0.15.0",
      summary:
        "Server-side product analytics that set no tracking cookie: a weekly-rotating salted visitor id, scoped to marketing and growth, with no client SDK and the processor disclosed on /privacy, /trust, and /dpa. A console craft pass unifies the design system into one surface recipe, a dense-table width tier, shared empty states, and a single product term (the LLM agent; MCP is the protocol). Approvals gain a live expiry countdown and a per-card risk tier, the audit log goes on a logging diet, mobile gets real operator cards, and self-approval becomes a named policy mode: single-operator or four-eyes."
    },
    %{
      date: ~D[2026-06-23],
      slug: "marketing-site-rebuilt",
      title: "The marketing site, rebuilt",
      tag: "v0.14.0",
      summary:
        "A ground-up rebuild of emisar.dev. A how-it-works walkthrough traces one real action through every gate with the actual payload; an MCP reference, a procurement-ready Trust page, a Data Processing Addendum, and a Guides surface fill out the funnel; the pack registry is searchable and the changelog is data-driven with an RSS feed. Behind the pages, a roughly 1,590-test QA suite across portal, runner, and mcp, a marketing-honesty pass that cut every claim we could not back, and domain metrics for run outcomes, approvals, and billing."
    },
    %{
      date: ~D[2026-06-22],
      slug: "the-gate-design-system",
      title: "\"The Gate\": a new identity and design system",
      tag: "v0.13.0",
      summary:
        "emisar gets a face: a gate logo and custom wordmark, a single emerald brand token in place of the old indigo and emerald mix, a signature display typeface, and material depth from film grain, emerald glow, and glass elevation, with the gate device drawn into the hero from the logo. The control plane moves onto the same brand token and type signature, and the marketing site is overhauled with a use-cases hub, a packs registry, a Trust page, ROI-tied pricing, and a WCAG AA contrast pass."
    },
    %{
      date: ~D[2026-06-19],
      slug: "security-review-and-datastore-packs",
      title: "Security-review hardening and the datastore pack wave",
      tag: "v0.12.0",
      summary:
        "A full security-review pass closes the sharp edges: a durable runbook-execution record ends a continuation ACL bypass, pack trust fails closed, a cancelled approval-gated run can no longer be approved and delivered, a privilege reduction disconnects the member's live sockets, approval grants are consumed in the same transaction as the run, MFA verifies against the current secret under a row lock, and the trusted pack hash is snapshotted at authorization. A datastore pack wave lands with it (CockroachDB, MongoDB replica-set lag, ClickHouse, Kubernetes and RKE2, Redis Sentinel, SNMP), along with live signing-key rotation over SIGHUP."
    },
    %{
      date: ~D[2026-06-17],
      slug: "signed-dispatch",
      title: "Client-attested signed dispatch",
      tag: "v0.11.0",
      summary:
        "End-to-end Ed25519 attestation on every dispatch. The MCP client signs each tools/call, the portal relays the signature untouched, and an enforcing runner verifies it before executing, so a compromised control plane can relay a request but never forge one. The emisar keygen command mints the keypair; runners advertise enforcement, their trusted key IDs, and a maximum attestation age; the runners index shows a Signed-only chip; and a refused run is its own terminal state."
    },
    %{
      date: ~D[2026-06-17],
      slug: "tenancy-and-console-redesign",
      title: "Multi-tenant URLs and the console redesign",
      tag: "v0.10.0",
      summary:
        "Slug-based tenant URLs nest the app under a per-account path with a cross-slug tenant guard, SSO sign-in lands on the team's branded page, and a per-account require-SSO switch forces members through the account's IdP. The console is rebuilt across five workstreams: nav regrouped into Operate, Fleet, and Settings; a single content-width scaffold; load errors that no longer read as empty; dead-end flashes that name the next move; and audit deep-links from every run, runner, and approval. New Credo layer-boundary checks and MCP bridge hardening (response caps, oversized-frame resilience, redirect refusal) ship alongside."
    },
    %{
      date: ~D[2026-06-16],
      slug: "sso-and-scim",
      title: "SSO, SCIM, and four-eyes approvals",
      tag: "v0.9.0",
      summary:
        "A configurable approval gate you set per policy: forbid self-approval and require a number of distinct approvers. OIDC single sign-on (Google Workspace, Okta, Keycloak) and SCIM 2.0 directory sync provision and deprovision from your IdP, map IdP groups to emisar roles, and have offboarding revoke a member's access and sessions automatically, with real-world interop for Okta header tokens and linking an IdP identity to an existing member. The shared component system fills out behind it with typed-confirm dialogs, selects, checkboxes, and an accessibility pass."
    },
    %{
      date: ~D[2026-06-14],
      slug: "fleet-operability-and-operator-ux",
      title: "Fleet operability and the operator-experience overhaul",
      tag: "v0.8.0",
      summary:
        "Multi-machine clustering so dispatch and Presence span Fly nodes, stale runs that re-dispatch to an online runner instead of stranding, and runbooks that honor a per-step runner target. A deep operator-experience sweep runs through runs, runbooks, approvals, the dashboard, team, and audit: streaming output, offline affordances, blast radius shown before dispatch, a live execution that rehydrates on refresh, recovery-code download, role-change confirms, and an escape hatch for an MFA lockout. The audit log gains actor, date-range, outcome, and free-text filters, the first shared component system lands, and the pack catalog reaches 73 packs and 1,096 actions."
    },
    %{
      date: ~D[2026-06-12],
      slug: "runbook-engine-and-scoped-policy",
      title: "The runbook engine, scoped policy, and a reliability pass",
      tag: "v0.7.0",
      summary:
        "The runbook execution engine arrives with grouped targets, parallel waves, and a live results page, and policy gains per-runner and per-group overrides. The safety rails tighten: approval expiry enforced at decision time, pack trust re-gated at approval, the policy and grant audit committed in the same transaction as the run, and rate limits on the unauthenticated and MCP endpoints. Runs stuck running on a dead runner now time out and re-dispatch on reconnect, and an opt-in shell break-glass pack ships for staging, over a top-to-bottom correctness, authorization-shape, and test-coverage pass."
    },
    %{
      date: ~D[2026-06-08],
      slug: "pack-expansion-and-hardening",
      title: "Pack catalog expansion, runbooks over MCP, and security hardening",
      tag: "v0.6.0",
      summary:
        "The catalog grows by fifteen packs (iscsi, multipath, bonding, frr, nic, victoriametrics, victorialogs, pfsense, traefik, tailscale, pure-flasharray, vector, typesense, zot), and emisar pack suggest recommends the ones a host actually runs. Runbooks become readable over MCP through list_runbooks and get_runbook, so an agent can fetch a saved playbook and run it step by step. Security hardening lands across the runner and bridge: an OAuth-consent privilege escalation closed, streaming output redacted across line boundaries, the script hash re-verified at exec time, and credentials streamed over stdin instead of argv."
    },
    %{
      date: ~D[2026-06-06],
      slug: "public-beta-control-plane",
      title: "Public beta control plane",
      tag: "v0.5.0",
      summary:
        "The hosted control plane opens. Connect an MCP client, scope it to selected runners, and run a declared catalog behind policy, now on Elixir 1.20 and OTP 29. The first marketing surface ships with it: comparison pages against SSH and a custom MCP server, the CSI data-loss use case, an animated home demo, and a zero-trust page mapping emisar to Anthropic's agent-safety framework."
    },
    %{
      date: ~D[2026-06-03],
      slug: "remote-mcp-over-oauth",
      title: "Remote MCP over OAuth 2.1",
      tag: "v0.4.0",
      summary:
        "An OAuth 2.1 authorization server lets a remote MCP connector authenticate and scope itself to your runners. Runner identity becomes stable through a durable external id so re-registration is idempotent, connection state moves to Phoenix Presence, and a live badge surfaces packs waiting for a trust review. The emisar pack uninstall command, pack setup blocks, and Sobelow and mix_audit scans in CI round it out."
    },
    %{
      date: ~D[2026-06-02],
      slug: "pack-registry-and-install-cli",
      title: "The pack registry and install CLI",
      tag: "v0.3.0",
      summary:
        "The emisar pack install command pulls one hash-verified pack at a time instead of dumping the whole catalog, with a no-service flag for binary-only installs and install-time config baking so a runner boots without hand-editing. MCP tool calls now return the real result, including failures, rather than a bare status of sent."
    },
    %{
      date: ~D[2026-06-01],
      slug: "approvals-audit-control-set",
      title: "Approvals, audit, and the control set",
      tag: "v0.2.0",
      summary:
        "The pieces that make it safe to act: human approvals with revocable standing grants, a SHA-256 hash-chained host journal alongside a searchable cloud audit and NDJSON SIEM export, account-wide MFA with recovery codes, request idempotency, versioned runbooks, and per-runner billing through Paddle. The first action-pack library ships with it."
    },
    %{
      date: ~D[2026-05-31],
      slug: "the-foundation",
      title: "The foundation",
      tag: "v0.1.0",
      summary:
        "Where it began: an outbound-only on-host runner that advertises and executes a typed catalog, YAML action packs with typed argument validation, a risk-tiered default-deny policy engine, and an append-only audit trail. A JSON-RPC MCP server with tools/list and tools/call exposes the catalog to any agent, and a docker-compose dev stack plus single-use enrollment keys make it runnable in minutes."
    }
  ]

  @doc "All changelog entries, newest first."
  def entries, do: @entries

  @doc "Display date, e.g. \"June 23, 2026\"."
  def display_date(%Date{} = date), do: Calendar.strftime(date, "%B %-d, %Y")

  @doc "RFC 822 pubDate for RSS, e.g. \"Tue, 23 Jun 2026 00:00:00 +0000\"."
  def rss_date(%Date{} = date), do: Calendar.strftime(date, "%a, %d %b %Y 00:00:00 +0000")

  @doc "Canonical URL for an entry (anchor on the changelog page)."
  def entry_url(%{slug: slug}), do: @base <> "/changelog#" <> slug
end
