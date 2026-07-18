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
      date: ~D[2026-07-17],
      slug: "installer-preserves-commented-zed-config",
      title: "The MCP installer preserves a commented Zed config",
      tag: "v0.31.1",
      summary:
        "Connecting Zed through the installer no longer drops to a manual step. Zed ships a settings.json with comments and trailing commas that the installer's strict JSON parser refused; it now adds the emisar server while keeping those comments, the trailing commas, and any servers already configured. The same comment-safe merge covers any editor that keeps a commented JSON config."
    },
    %{
      date: ~D[2026-07-17],
      slug: "browser-approved-connect-and-pack-lifecycle",
      title: "Browser-approved agent connect and pack lifecycle control",
      tag: "v0.31.0",
      summary:
        "Connecting a local agent no longer moves an API key by hand. The installer opens a browser approval, you approve the connection on a consent page, and per-client keys are written straight into the agent's config — the secret never touches the clipboard, shell history, or a process argument, and the copy-the-key step is gone. The same installer now sets up thirteen MCP clients. The pack catalog becomes something operators run, not just watch: delete a pack or a single version, revoke trust on a version, auto-remove versions no runner has advertised for a set number of days, and see a quiet update-available hint on outdated ones. A runner still lagging on a version a security fix retired now reads as retired and points at the upgrade, instead of posing as an unknown pack asking to be trusted — approving it would have re-authorized the vulnerable bytes. Essential text on every marketing and console page is raised to WCAG AA contrast, kept there by a new check. Five pack actions that could read a leading-dash value as a command flag are fixed and their old versions retired, and three that dump container or process environment now require approval. Nomad reaches 0.2.0 with deployment control and metadata-filtered discovery, the runner CLI reloads the daemon on its own after a pack change, and under-permissioned roles now get a clean denial instead of a server error. One upgrade step for self-hosted runners: rename the config key auth_key_env to enrollment_key_env and re-mint any keys that were never enrolled — connected runners keep working."
    },
    %{
      date: ~D[2026-07-16],
      slug: "database-enforced-tenant-isolation-and-steadier-dispatch",
      title: "Database-enforced tenant isolation and steadier dispatch",
      tag: "v0.30.0",
      summary:
        "Tenant isolation now lives in the database itself: every runner-owned child row carries a composite foreign key to its account, and CHECK constraints backstop the security-relevant enums, so a cross-tenant or out-of-range write is refused at the row rather than only in application code. A retired pack's re-trust control no longer crashes the packs page. Dispatch recovers more of its own edge cases: a runner at capacity redelivers the dispatches it refused, the stale-dispatch sweep drains the oldest queued first, and stuck pending runs advance instead of stranding. Active sessions each render as their own row with their own address, sign-in time, and revoke. Public pages and error responses now carry the same Content-Security-Policy as the rest of the site, Sentry is disclosed as a subprocessor with its events scrubbed of personal data before they leave, and a runner that requires signed dispatch announces it over MCP. Operators also get faster run search on large accounts and direct paging for severe database and load-balancer alarms."
    },
    %{
      date: ~D[2026-07-16],
      slug: "leaner-mcp-results-and-hardened-pack-catalog",
      title: "Leaner MCP results and a hardened pack catalog",
      tag: "v0.29.0",
      summary:
        "MCP results now meet LLM clients where they are: canonical string forms of integers and booleans coerce instead of failing the call, every rejected argument names its field and the JSON type it was sent as, and run summaries omit what carries no signal — streams that produced no bytes, completeness flags that are simply true, and per-stream digests — so a typical summary shrinks by a third. The pack catalog closes two cross-pack gaps: secret-dense config and environment dumps now require approval, Redis ACL password hashes are redacted from low-risk reads, and exec-style arguments reject a leading dash so a hostile value cannot be read as a flag. Disabling two-factor authentication now demands a fresh step-up challenge, and production session cookies always carry the Secure flag."
    },
    %{
      date: ~D[2026-07-16],
      slug: "upgrade-safe-runners-and-honest-fleet-alarms",
      title: "Upgrade-safe runners and honest fleet alarms",
      tag: "v0.28.0",
      summary:
        "Runner upgrades now migrate the durable dispatch log across format and location changes instead of silently refusing every dispatch afterwards, and one broken installed pack degrades just that pack — named on the runner page and in MCP diagnostics with its load error — rather than crash-looping the whole runner. An offline runner now shows its real connection status instead of tamper-flavored trust alarms about a stale advertisement. The installer verifies dispatch state with the staged binary before touching a running service, and emisar doctor explains a corrupt dispatch log, a degraded pack, and the last cloud rejection offline. Sign-in enforcement for SSO and MFA requirements now covers every controller route, SCIM and other machine endpoints are rate-limited, runner connections assert a TLS 1.2 floor, and operators get direct alerts for database-down and no-healthy-backend conditions."
    },
    %{
      date: ~D[2026-07-16],
      slug: "reliable-runner-startup-and-clearer-mcp-failures",
      title: "Reliable runner startup and clearer MCP failures",
      tag: "v0.27.0",
      summary:
        "Runner upgrades now use one final durable dispatch journal, refuse to connect when that state is corrupt, keep unsigned installations independent from signing state, and redact sensitive values from failure causes before reporting them. MCP run summaries expose a bounded terminal failure message, while connector setup keeps key-bearing commands out of shell history and OAuth consent lets a person choose the account they intend to connect. Delivery also lets newer non-destructive production plans supersede stale ones without adding a second approval gate."
    },
    %{
      date: ~D[2026-07-16],
      slug: "reconnect-safe-runs-and-clearer-agents",
      title: "Reconnect-safe runs and a clearer agents list",
      tag: "v0.26.0",
      summary:
        "When a runner drops its connection and comes back, the control plane recovers the runs that were in flight instead of stranding them, and the runner repairs any packs it kept across an upgrade before resuming work. It also skips processes that were already cancelled, reports a failed local audit honestly instead of masking it, and bounds the action catalog it advertises. In the console, the LLM agents list now groups by the person behind each key and shows each connection's emisar-mcp bridge version inline, so an outdated bridge is obvious and one step from the upgrade command."
    },
    %{
      date: ~D[2026-07-16],
      slug: "stricter-runner-results-and-cleaner-settings",
      title: "Stricter runner results and cleaner settings",
      tag: "v0.25.4",
      summary:
        "The runner now rejects broken action contracts, invalid execution options, unchecked path targets, and out-of-range result metadata before those values cross the host boundary. Pack releases rebuild from the live registry history, and account settings drop redundant state labels."
    },
    %{
      date: ~D[2026-07-15],
      slug: "versioned-registry-schemas-for-append-only-publishing",
      title: "Versioned registry schemas for append-only publishing",
      tag: "v0.25.3",
      summary:
        "Pack Registry schema publishing now versions immutable JSON schema filenames and identifiers, so a changed catalog or action schema appends new objects instead of colliding with a prior release. The publisher still creates every immutable object before moving catalog pointers, and tests tie each schema identifier to its public object path."
    },
    %{
      date: ~D[2026-07-15],
      slug: "exact-action-validation-and-stronger-ui-proof",
      title: "Exact action validation and stronger UI proof",
      tag: "v0.25.2",
      summary:
        "Action arguments now keep numeric membership checks exact across the portal and runner, reject invalid allowed values before a pack or run proceeds, and validate the runner execution envelope instead of silently dropping malformed options. Contributor workflows also gain a frontier review preset, durable loop knowledge, a backlog drawer, and required before-and-after screenshot evidence for UI fixes."
    },
    %{
      date: ~D[2026-07-15],
      slug: "cleaner-setup-and-reliable-release-publication",
      title: "Cleaner setup and reliable release publication",
      tag: "v0.25.1",
      summary:
        "Runner and connector setup now keeps one-line commands compact, uses shorter Claude.ai instructions, and leaves transport diagnostics out of customer screens. Fleet examples distinguish supported from unsupported runners, account settings use quieter status labels, and release publication waits for the tagged commit's required CI result instead of losing a race. Runner argument parsing also accepts numeric strings only when they use valid JSON number syntax."
    },
    %{
      date: ~D[2026-07-15],
      slug: "durable-execution-and-native-mcp",
      title: "Durable execution and a tighter MCP boundary",
      tag: "v0.25.0",
      summary:
        "Runner execution now begins only after durable audit evidence and remains bound to the trusted pack, dispatch record, output digest, and terminal result. The runner also contains cancelled process trees, rejects ambiguous paths and inexact numeric limits, and redacts secrets across log rotation. The native MCP endpoint now exposes twelve server-owned tools with bounded waits, crash-durable mutation recovery, and safer key promotion. Coordinated installers, rollback-aware releases, multi-zone delivery, and clearer connector setup make the operating path easier to inspect."
    },
    %{
      date: ~D[2026-07-13],
      slug: "delivery-trust-and-mcp-discovery",
      title: "Stronger delivery controls and clearer trust evidence",
      tag: "v0.24.1",
      summary:
        "Delivery now rejects stale or incomplete plans, authenticates installer release metadata, narrows production credentials, and keeps published images and packs tied to tested bytes. The Trust Center leads with current controls and a live DNSSEC chain, while the official MCP Registry description explains emisar in plain language for people who discover it outside the website."
    },
    %{
      date: ~D[2026-07-12],
      slug: "release-integrity-and-pack-registry",
      title: "Hardened hosting, safer releases, and a public status page",
      tag: "v0.24.0",
      summary:
        "The hosted platform moved to hardened cloud infrastructure with zero-downtime rollouts, a private-network database, and independent external monitoring behind a public status page at status.emisar.dev. Portal releases now publish the exact image exercised by CI, binary releases are immutable and reproducible, and production plans queue in order without replacing an operator's pending review. The pack registry serves from its own hostname, registry.emisar.dev, with anonymous access narrowed to exact object reads, generation-specific verification, and end-to-end tarball checks."
    },
    %{
      date: ~D[2026-07-07],
      slug: "recurrent-jobs-billing-sync-runner-install",
      title: "More reliable background work and a cleaner runner setup",
      tag: "v0.23.0",
      summary:
        "Routine product work is now more predictable: approval expiry, audit retention, billing sync, sign-in cleanup, and timed-out runs are handled by the control plane itself. Billing contact sync keeps customer records tied to active account owners, and runner setup now puts the install script details where operators need them."
    },
    %{
      date: ~D[2026-07-06],
      slug: "annual-billing-team-sso-security-hardening",
      title: "Annual billing, Team-owned SSO, and safer input handling",
      tag: "v0.22.0",
      summary:
        "Billing now supports monthly or annual checkout, shows recent invoices, and lets operators download invoice PDFs from the console. SSO moved into Team, where pending access requests, connection status, sign-in links, 2FA enforcement, and Require SSO live next to the roster. The same pass tightened how emisar handles oversized directory-sync data, runner output, signup recovery, email changes, and account-scoped billing or runner actions."
    },
    %{
      date: ~D[2026-07-05],
      slug: "console-on-canvas-policy-and-pack-clarity",
      title: "A calmer, clearer console",
      tag: "v0.21.0",
      summary:
        "The console now uses one page language across fleet, agents, policies, packs, runbooks, billing, approvals, and audit. Empty states explain the next useful action, dangerous actions use the same confirmation dialog, machine identifiers are easy to copy, and navigation looks like navigation rather than a row of buttons. Policies show what a rule allows, approves, or denies against the account's actual catalog, and pack search can narrow by risk tier or matching action."
    },
    %{
      date: ~D[2026-07-03],
      slug: "forensic-audit-and-decision-records",
      title: "Audit and approvals read like records",
      tag: "v0.20.0",
      summary:
        "The audit trail is easier to scan during an incident: each row makes the actor, target, action, and outcome clearer, and streaming audit events to a SIEM moved to its own managers-only page, off the browse view. Approval detail pages now open with the decision state, then show the command, arguments, reason, policy evidence, reviewer note, and timestamps in one record instead of scattered panels."
    },
    %{
      date: ~D[2026-07-02],
      slug: "billing-checkout-mfa-and-shared-components",
      title: "Checkout, 2FA sign-in, and cleaner account forms",
      tag: "v0.19.0",
      summary:
        "Checkout now follows the selected plan, and billing-manager seats can manage billing without receiving broader admin powers. Accounts that require 2FA can challenge after a magic-link sign-in with TOTP or a recovery code. Code entry, secret reveal, enrollment steps, switches, cards, and mobile list rows now share the same console patterns, so repeated workflows feel familiar instead of rebuilt per page."
    },
    %{
      date: ~D[2026-07-01],
      slug: "directory-owned-members-and-runner-scopes",
      title: "Directory sync owns directory-managed access",
      tag: "v0.18.0",
      summary:
        "Directory-managed members now behave consistently: synced roles stay owned by the IdP, deactivated users arrive suspended, manual suspensions are not undone by later syncs, and IdP-deactivated members cannot be reinstated from emisar. Runner scope selection is clearer and reused across invitations and MCP keys, and MCP keys can be limited by action and runner scope before a dispatch reaches a runner."
    },
    %{
      date: ~D[2026-06-30],
      slug: "sso-setup-and-audit-retention",
      title: "SSO setup and audit retention become inspectable",
      tag: "v0.17.0",
      summary:
        "SSO setup now has dedicated connection pages with pending access requests, a test-connection step, synced users, sync health, and read-only provider fields after creation. Audit retention is easier to reason about: plan changes affect retention going forward rather than silently erasing existing rows, exports record that they happened, and important identity, plan, retention, and action-run events carry the details an operator needs later."
    },
    %{
      date: ~D[2026-06-26],
      slug: "passwordless-signed-dispatch-and-pack-verification",
      title: "Passwordless sign-in, signed dispatch, and verified packs",
      tag: "v0.16.0",
      summary:
        "emisar now signs users in with magic links or SSO only. Email changes require a fresh verification step, and invite and confirmation emails carry sign-in links instead of asking for a password. Signed dispatch gives runners a way to reject requests that were not made by a configured client, MCP keys gained action scopes, expiry, kind labels, and rotation, and the pack test harness expanded across the database, Kubernetes, routing, Nomad, and firewall packs."
    },
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
        "Multi-machine clustering so dispatch and Presence span control-plane nodes, stale runs that re-dispatch to an online runner instead of stranding, and runbooks that honor a per-step runner target. A deep operator-experience sweep runs through runs, runbooks, approvals, the dashboard, team, and audit: streaming output, offline affordances, blast radius shown before dispatch, a live execution that rehydrates on refresh, recovery-code download, role-change confirms, and an escape hatch for an MFA lockout. The audit log gains actor, date-range, outcome, and free-text filters, the first shared component system lands, and the pack catalog reaches 73 packs and 1,096 actions."
    },
    %{
      date: ~D[2026-06-12],
      slug: "runbook-engine-and-scoped-policy",
      title: "The runbook engine, scoped policy, and a reliability pass",
      tag: "v0.7.0",
      summary:
        "The runbook execution engine arrives with grouped targets, parallel waves, and a live results page, and policy gains per-runner and per-group overrides. The safety rails tighten: approval expiry enforced at decision time, pack trust re-gated at approval, the policy and grant audit committed in the same transaction as the run, and rate limits on the unauthenticated and MCP endpoints. Runs stuck running on a dead runner now time out instead of hanging forever, and an opt-in shell break-glass pack ships for staging, over a top-to-bottom correctness, authorization-shape, and test-coverage pass."
    },
    %{
      date: ~D[2026-06-08],
      slug: "pack-expansion-and-hardening",
      title: "Pack catalog expansion, runbooks over MCP, and security hardening",
      tag: "v0.6.0",
      summary:
        "The catalog grows by fourteen packs (iscsi, multipath, bonding, frr, nic, victoriametrics, victorialogs, pfsense, traefik, tailscale, pure-flasharray, vector, typesense, zot), and emisar pack suggest recommends the ones a host actually runs. Runbooks become readable over MCP through list_runbooks and get_runbook, so an agent can fetch a saved runbook and run it step by step. Security hardening lands across the runner and bridge: an OAuth-consent privilege escalation closed, streaming output redacted across line boundaries, the script hash re-verified at exec time, and credentials streamed over stdin instead of argv."
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
