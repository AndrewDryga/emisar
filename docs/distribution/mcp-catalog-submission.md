# MCP catalog submission kit

The single source of truth for listing emisar in the Official MCP Registry, the
Claude connectors directory, the Cursor MCP marketplace, and ChatGPT
apps/connectors. Everything a vendor form asks for is here in an approved,
factual form so a human filling out a portal never has to invent copy or guess a
URL.

**Scope.** This kit prepares evidence and copy. It does **not** submit anything
to any vendor, and it holds **no** secrets — reviewer credentials, private keys,
session cookies, and OAuth tokens live only in the operator secret store (1Password
vault `emisar-ops`), never in git. Screenshots referenced here are captured from
the real product by an operator, not fabricated.

**Freshness rule.** Vendor forms change. The Claude / ChatGPT / Cursor flows below
are transcribed from `/docs/connect-an-llm` (kept current) and the live endpoint;
the Official MCP Registry section is pinned to the live `server.json` schema
`2025-12-11`. Before any actual submission, re-open the vendor's current form and
diff it against the field list here — that re-check is a **human-owned** step
flagged per platform in [§11](#11-human-owned-steps-remaining).

**Contents**

1. [Canonical product facts](#1-canonical-product-facts)
2. [Reusable listing copy](#2-reusable-listing-copy)
3. [Icons & screenshots](#3-icons--screenshots)
4. [Golden & negative prompts](#4-golden--negative-prompts)
5. [Official MCP Registry](#5-official-mcp-registry)
6. [Claude connectors directory](#6-claude-connectors-directory)
7. [Cursor MCP marketplace](#7-cursor-mcp-marketplace)
8. [ChatGPT apps / connectors](#8-chatgpt-apps--connectors)
9. [Tool metadata inventory](#9-tool-metadata-inventory)
10. [Public URL verification](#10-public-url-verification)
11. [Human-owned steps remaining](#11-human-owned-steps-remaining)

The reviewer tenant, sandbox runner, demo policy, run history, and credential
rotation/deletion procedure are in **[reviewer-tenant.md](reviewer-tenant.md)**.

---

## 1. Canonical product facts

One block, reused by every platform. All values below were verified live against
`https://emisar.dev` on 2026-07-10 (see [§10](#10-public-url-verification) for the
probe log) and cross-read against the portal source.

### Identity

| Field | Value |
|---|---|
| Product name | **emisar** |
| One-liner | One governed MCP endpoint for real infrastructure actions — gated, approved, and audited. |
| MCP server name (advertised in `initialize`) | `emisar` |
| Protocol versions supported | `2025-06-18` (preferred), `2024-11-05` |
| Transport | Remote **streamable-http** JSON-RPC 2.0 over HTTPS |
| Source repository | `https://github.com/andrewdryga/emisar` |
| Website | `https://emisar.dev` |
| Vendor / publisher | emisar |

### Endpoints

| Purpose | Method + path | Full URL |
|---|---|---|
| **MCP server (canonical)** | `POST /api/mcp/rpc` | `https://emisar.dev/api/mcp/rpc` |
| OAuth protected-resource metadata (RFC 9728) | `GET /.well-known/oauth-protected-resource` | `https://emisar.dev/.well-known/oauth-protected-resource` |
| OAuth AS metadata (RFC 8414) | `GET /.well-known/oauth-authorization-server` | `https://emisar.dev/.well-known/oauth-authorization-server` |
| Dynamic client registration | `POST /oauth/register` | `https://emisar.dev/oauth/register` |
| Authorization (human consent) | `GET/POST /oauth/authorize` | `https://emisar.dev/oauth/authorize` |
| Token | `POST /oauth/token` | `https://emisar.dev/oauth/token` |
| REST siblings (non-JSON-RPC) | `GET /api/mcp/runners`, `GET /api/mcp/tools`, `POST /api/mcp/tools/:action_id`, `GET /api/mcp/runs/:id` | under `https://emisar.dev/api/mcp/` |

The cloud connectors (Claude.ai, ChatGPT) need **only the MCP server URL** —
`https://emisar.dev/api/mcp/rpc`. Everything else is discovered.

### Authentication

emisar is a full **OAuth 2.1 authorization server** for remote MCP connectors,
plus static bearer keys for local/CLI clients.

- **OAuth (cloud connectors).** The connector is handed only a URL; it reads the
  protected-resource metadata, self-registers via DCR (no pre-created client id or
  secret), and sends the operator through a one-time emisar sign-in + consent
  screen. Public clients, **PKCE S256 only**. Live-advertised AS metadata:
  - `authorization_endpoint`: `https://emisar.dev/oauth/authorize`
  - `token_endpoint`: `https://emisar.dev/oauth/token`
  - `registration_endpoint`: `https://emisar.dev/oauth/register`
  - `grant_types_supported`: `authorization_code`, `refresh_token`
  - `response_types_supported`: `code`
  - `code_challenge_methods_supported`: `S256`
  - `token_endpoint_auth_methods_supported`: `none`
  - `scopes_supported`: `mcp`, `offline_access`
  - `bearer_methods_supported`: `header`
  - The issued access token is `emo-`-prefixed and RFC 8707 audience-bound to the
    `…/api/mcp/rpc` resource.
- **Static key (local/CLI/HTTP).** An `emk-`-prefixed per-account API key sent as
  `Authorization: Bearer emk-…`. Minted from the dashboard's **LLM agents** page.
- Both bearer forms resolve to a hashed `api_keys` row. The tool surface requires
  the key's kind to be `mcp` (an audit-export token authenticates but is refused
  with JSON-RPC `-32002`). Rate limit: **300 requests/min per bearer**.
- An unauthenticated request returns `401` with
  `WWW-Authenticate: Bearer resource_metadata="https://emisar.dev/.well-known/oauth-protected-resource"`
  (verified live).

> **Internal API-key scopes vs OAuth scopes.** The OAuth protocol scopes a
> connector requests are `mcp` and `offline_access`. Internally each key also
> carries capability scopes (`actions:read`, `actions:execute`, `audit:read`) and a
> per-member runner ACL — this is what actually bounds what a connected LLM may do.
> Vendor forms only ever see the OAuth scopes.

### Tool surface

`tools/list` returns a **dynamic, per-account** set:

- **One tool per distinct catalog action** the authenticated key can dispatch —
  the tool name is the action id verbatim (e.g. `linux.uptime`,
  `showcase.path_validation`), sorted alphabetically, filtered by the minting
  operator's runner scope. Two operators of the same account can see **different**
  tool lists.
- **Six fixed synthetic tools**, always present: `wait_for_run`, `list_runbooks`,
  `get_runbook`, `execute_runbook`, `create_runbook_draft`, `recent_runs`.

Annotations are risk-derived per tool (`readOnlyHint` for `low`-risk read actions,
`destructiveHint` for `high`/`critical`, `openWorldHint` true, plus
`idempotentHint`). Every tool is stamped with an OAuth `securitySchemes` marker
(`type: oauth2`, `scopes: ["mcp"]`). Every action call **must** carry a `reason`
string — it lands on the run and is shown to approvers.

- **Longest fixed tool name:** `create_runbook_draft` (20 chars).
- **Tool-name format caveat:** action-tool names are the dotted `action_id`
  verbatim (`vendor.verb`). Some catalogs/clients restrict tool names to
  `^[a-zA-Z0-9_-]{1,64}$` (no `.`). Before submitting to a platform that validates
  tool names, confirm it accepts a `.` — see each platform's "tool-name check"
  line. The reviewer tenant's showcase-only catalog keeps every name ≤ 24 chars
  (`showcase.path_validation`), well under 64.

To capture the **exact** count/names/annotations for a specific reviewer tenant at
submission time, see [§9](#9-tool-metadata-inventory).

### Public URLs (for "docs / privacy / terms" fields)

| Field a form asks for | URL |
|---|---|
| How to connect / integration docs | `https://emisar.dev/docs/connect-an-llm` |
| MCP tool reference | `https://emisar.dev/docs/mcp-reference` |
| Docs home | `https://emisar.dev/docs` |
| Quickstart | `https://emisar.dev/docs/quickstart` |
| Security model | `https://emisar.dev/docs/security-model` |
| Privacy policy | `https://emisar.dev/privacy` |
| Security overview | `https://emisar.dev/security` |
| Trust (subprocessors, compliance, SLA) | `https://emisar.dev/trust` |
| Pricing | `https://emisar.dev/pricing` |
| Terms of service | `https://emisar.dev/terms` |
| Data Processing Addendum | `https://emisar.dev/dpa` |
| Support | `mailto:support@emisar.dev` (no `/support` page — support is an email) |
| Security contact | `mailto:security@emisar.dev` |
| Sales / DPA request | `mailto:sales@emisar.dev` |

### Data handling (for privacy/security review fields)

- **What emisar processes:** operator account data (name, email), account/runner
  configuration, action dispatch records (which tool, which client, which key,
  the `reason`, and the run's stdout/stderr), and audit events. Runner output is
  processed to return results and is retained per the account's audit-retention
  plan (7 / 90 / 365 days).
- **What it does not do:** no client-side trackers, no third-party analytics SDK,
  cookieless first-party analytics only. Full card numbers are never seen or stored
  (Paddle handles payment).
- **Subprocessors:** Fly.io (app hosting + managed PostgreSQL, US region), Paddle
  (payments), Postmark (transactional email), Mixpanel (server-side, cookieless
  marketing/growth analytics — never runner data). Canonical list on `/trust` and
  `/privacy`.
- **Data residency:** production data stays in the United States.
- **Encryption:** in transit (TLS) and at rest; credentials hashed at rest.
- **Compliance posture (state it plainly):** emisar does **not yet** hold SOC 2 or
  ISO 27001 (SOC 2 Type II is on the roadmap). In place today: least-privilege
  access, enforced MFA, a searchable audit with a hash-chained host journal, a
  signable DPA, and a security questionnaire on request. Insurance:
  professional-indemnity USD $1M, general-liability USD $2M.
- **Deletion:** account data deletion on request to `support@emisar.dev`; see
  `/privacy`.

---

## 2. Reusable listing copy

Approved strings. Trim to each platform's length limit rather than rewording off
the facts above.

- **Name:** `emisar`
- **Tagline (≤ 60 chars):** `Governed MCP for real infrastructure actions`
- **Short description (≤ 100 chars, fits the MCP Registry limit):**
  `One governed MCP endpoint for infrastructure actions — gated by policy, approval, and audit.`
- **Category / tags:** `DevOps`, `Infrastructure`, `Security`, `Automation`,
  `Approvals & audit`
- **Long description (Claude / ChatGPT / Cursor):**

  > emisar is a control plane that lets an LLM run real infrastructure actions on
  > your fleet — safely. Instead of handing an agent raw SSH, you point it at one
  > MCP endpoint that exposes an approved catalog of actions. Every call is checked
  > against your policy (read-only actions run immediately; risky ones pause for a
  > human to approve; anything outside the catalog is denied by default), attributed
  > to the accountable operator, and written to a tamper-evident audit log. The tool
  > list is per-account and reflects exactly what your policy and runner scope allow
  > — nothing more. Connect over OAuth (paste one URL, no keys to manage) or a
  > static key for local clients.

- **What the connector can do (consent-screen summary):** run the infrastructure
  actions your policy already permits, attributed to you; risky actions still wait
  for a human approver; read the audit trail (if granted). It cannot exceed your
  policy or reach runners outside your scope.

---

## 3. Icons & screenshots

### Icon assets (already in the repo, served from prod)

All under `portal/apps/emisar_web/priv/static/`, reachable at
`https://emisar.dev/<path>`:

| Asset | Path | Dimensions | Use |
|---|---|---|---|
| Square mark (SVG) | `images/brand/emisar-icon.svg` | 390×390 | Vector listing icon |
| Square mark (PNG) | `android-chrome-512x512.png` | 512×512 | Raster listing icon (most catalogs) |
| Square mark (PNG) | `android-chrome-192x192.png` | 192×192 | Smaller raster fallback |
| Apple touch icon | `apple-touch-icon.png` | 180×180 | iOS-style tile |
| Favicon (SVG) | `favicon.svg` | 512×512 viewBox | Browser/registry favicon |
| Wordmark logo | `images/brand/emisar-logo.svg` | 1320×390 | **Not** for a square slot |
| OpenGraph card | `images/og/emisar-og.webp` | — | Social preview |

Platform icon rules to check at submission time (they drift): most want a **square
PNG ≥ 512×512** with a transparent or solid background — use
`android-chrome-512x512.png`. The MCP Registry accepts an icon **URL**; point it at
`https://emisar.dev/android-chrome-512x512.png` (confirmed `200`). No new asset
needs to be produced.

### Screenshots (captured from the real product — human-owned)

Screenshots must come from the reviewer tenant driving real flows, never mockups.
Capture these from the reviewer session (see
[reviewer-tenant.md](reviewer-tenant.md)) and store the PNGs in the ops vault, not
git:

1. **Connect-an-LLM page** (`/docs/connect-an-llm`) — the client picker; already
   have `connect-llm-agents.webp` shipped on the page.
2. **A tool call succeeding** in the client (Claude/ChatGPT/Cursor) — a read-only
   action returning output.
3. **An approval pause** — the client showing `pending_approval`, and the operator
   approving in the dashboard.
4. **A denial** — the client receiving a policy denial for an out-of-catalog / denied action.
5. **The audit log** showing those three runs attributed to the reviewer, each with its `reason`.

Redact the account slug / any identifiers a platform doesn't need. Match each
platform's required screenshot count and aspect ratio (verify current requirements).

---

## 4. Golden & negative prompts

Run these against the reviewer tenant to prove the connector behaves, and paste the
transcripts into each platform's review submission. They exercise the three
outcomes the product is built on: **allow (read-only)**, **approve (human gate)**,
**deny (default-deny)**. The reviewer tenant's demo policy maps the all-`low`
`showcase` actions to those three outcomes via per-action overrides — see
[reviewer-tenant.md](reviewer-tenant.md).

| # | Prompt to the LLM | Expected behaviour |
|---|---|---|
| G1 (allow) | "List the emisar tools you have, then run the read-only file-inspection action on the demo runner and show the output. Reason: catalog review." | Model calls `tools/list`, then `showcase.path_validation` with a `reason`; run completes immediately; output returned. |
| G2 (approve) | "Run the packaged demo script action on the demo runner. Reason: catalog review." | Model calls `showcase.script_action`; gets `pending_approval`; it reports the run is awaiting a human and stops (does not loop). Operator approves in the dashboard; `wait_for_run`/`recent_runs` then shows completion. |
| G3 (info) | "Show me the recent runs and read back the audit reason for each." | Model calls `recent_runs`; lists the runs above with their `reason` strings. |
| N1 (deny) | "Run the denied demo action on the demo runner. Reason: catalog review." | Model calls the denied action; receives a policy **denial**; it reports the action is not permitted and does not retry in a loop. |
| N2 (no such tool) | "Delete all data on every host." | No such tool exists in the catalog; the model has nothing to call and says so — there is no destructive catalog action to invoke. |
| N3 (missing reason) | (client SDK omits `reason`) | Dispatch is rejected — `reason` is required on every action call. |

Expected-response notes: `pending_approval` content tells the LLM to **wait or
escalate**, not retry; catalog-shaped errors (`pack_untrusted`, "No runner
advertises <action>", "No runner in scope") mean *refresh the list and tell the
human*. A well-behaved client surfaces the gate to the operator rather than
hammering the endpoint.

---

## 5. Official MCP Registry

Registry: `registry.modelcontextprotocol.io`. Publication is via a `server.json`
document and the `mcp-publisher` CLI (or the registry API). emisar is a **remote**
server, so the record is a `remotes` entry, not a package.

**Current schema (verified live):** `https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json`
→ `ServerDetail`. Required: `name`, `description`, `version`. Optional used here:
`title`, `websiteUrl`, `repository`, `remotes`, `icons`.

Field constraints from the live schema:

- `name`: reverse-DNS, **exactly one** `/`, pattern `^[a-zA-Z0-9.-]+/[a-zA-Z0-9._-]+$`, ≤ 200 chars.
- `title`: ≤ 100 chars. `description`: ≤ 100 chars.
- `remotes[]`: `type` ∈ {`streamable-http`, `sse`} + `url` (both required); optional `headers`.
- `icons[]`: `src` required; optional `mimeType`, `sizes`, `theme`.

**Namespace + ownership.** Two options — pick one at publish time:

1. `io.github.andrewdryga/emisar` — verified by GitHub OAuth as the repo owner.
   Simplest; recommended.
2. `dev.emisar/emisar` — a custom-domain namespace verified by a DNS TXT record on
   `emisar.dev`. Use only if we want the branded namespace; adds a DNS step.

**Proposed `server.json`** (fill `version` to the current `mcp-v*` release tag):

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
  "name": "io.github.andrewdryga/emisar",
  "title": "emisar",
  "description": "Governed MCP for real infrastructure actions — gated, approved, audited.",
  "version": "0.0.0",
  "websiteUrl": "https://emisar.dev",
  "repository": {
    "url": "https://github.com/andrewdryga/emisar",
    "source": "github"
  },
  "remotes": [
    { "type": "streamable-http", "url": "https://emisar.dev/api/mcp/rpc" }
  ],
  "icons": [
    { "src": "https://emisar.dev/android-chrome-512x512.png", "mimeType": "image/png", "sizes": "512x512" }
  ]
}
```

**Field-by-field checklist**

- [ ] `description` ≤ 100 chars (the string above is 72).
- [ ] `title` ≤ 100 chars.
- [ ] `version` set to the current release (see the latest `mcp-v*` tag; the registry rejects a re-publish of an existing version).
- [ ] `remotes[0].url` = `https://emisar.dev/api/mcp/rpc`, type `streamable-http`.
- [ ] Icon URL returns `200` and is square PNG (512×512 asset confirmed present).
- [ ] Namespace verified (GitHub OAuth for `io.github.andrewdryga`, or DNS TXT for `dev.emisar`).
- [ ] Tool-name check: the registry validates `server.json`, not tool names, so the dotted action-tool names are fine here.

**Human-owned:** run `mcp-publisher login` (GitHub) → `mcp-publisher publish`; confirm the record appears in `GET /v0/servers`.

---

## 6. Claude connectors directory

The connect flow (from `/docs/connect-an-llm`, current):

Claude.ai connects to a **remote MCP URL over OAuth** — no client id/secret, no
token field. Directory listing reuses the [§2](#2-reusable-listing-copy) copy.

**Listing / setup fields**

| Field | Value |
|---|---|
| Connector name | `emisar` |
| Remote MCP server URL | `https://emisar.dev/api/mcp/rpc` |
| Authentication | OAuth (Dynamic Client Registration; leave Client ID / Secret **empty**) |
| Category | DevOps / Infrastructure / Security |
| Short + long description | [§2](#2-reusable-listing-copy) |
| Icon | `emisar-icon.svg` / `android-chrome-512x512.png` ([§3](#3-icons--screenshots)) |
| Privacy policy | `https://emisar.dev/privacy` |
| Terms | `https://emisar.dev/terms` |
| Support | `support@emisar.dev` |
| Security contact | `security@emisar.dev` |

**End-user setup steps to document in the listing:** Settings → Connectors → **+**
→ Add custom connector → paste the URL → leave Advanced (OAuth) settings empty →
Add → sign in to emisar → Authorize. Team/Enterprise: an Owner adds it under
Organization settings → Connectors.

**Field-by-field checklist**

- [ ] URL returns the RFC 9728 challenge unauthenticated (verified: `401` + `WWW-Authenticate`).
- [ ] DCR works end-to-end from a clean Claude account (human-owned live test).
- [ ] Consent screen text matches the "what the connector can do" summary.
- [ ] Golden + negative prompts ([§4](#4-golden--negative-prompts)) run green in Claude against the reviewer tenant.
- [x] Every tool has a bounded `title` and accurate `readOnlyHint`/`destructiveHint` — certified in source ([§9 static guarantees](#9-tool-metadata-inventory)), 2026-07-10.
- [ ] Tool-name check: confirm Claude accepts dotted action-tool names, or that the reviewer tenant's showcase names are acceptable ([§9 certification caveat](#9-tool-metadata-inventory)).

**Human-owned:** submit through Anthropic's current directory intake form; complete
any Anthropic security review; provide reviewer-tenant credentials via the secure
channel Anthropic specifies (never in the form).

---

## 7. Cursor MCP marketplace

Cursor supports both the remote endpoint (recent builds) and the stdio bridge.
Prefer the **remote** entry for the marketplace so there's nothing to install.

Cursor now distributes MCP integrations as **Marketplace plugins**. A ready-to-ship
plugin scaffold — `.cursor-plugin/plugin.json`, a remote-OAuth `mcp.json`, README,
changelog, Apache-2.0 license, and icon — lives in
[`cursor-plugin/`](cursor-plugin/); its `PUBLISHING.md` carries the human-owned
publish steps. The fields below are the listing copy that scaffold and the
publisher form reuse.

**Listing fields**

| Field | Value |
|---|---|
| Name | `emisar` |
| Server type | Remote (streamable-http) |
| URL | `https://emisar.dev/api/mcp/rpc` |
| Auth | OAuth |
| Description | [§2](#2-reusable-listing-copy) |
| Icon | [§3 assets](#3-icons--screenshots) |
| Docs | `https://emisar.dev/docs/connect-an-llm` |
| Repository | `https://github.com/andrewdryga/emisar` |

**Stdio fallback (for the `mcp.json` deep-link / one-click install):**

```json
{
  "mcpServers": {
    "emisar": {
      "command": "emisar-mcp",
      "env": { "EMISAR_URL": "https://emisar.dev", "EMISAR_API_KEY": "emk-..." }
    }
  }
}
```

**Field-by-field checklist**

- [ ] Remote entry connects over OAuth from a clean Cursor install (human-owned).
- [ ] If publishing the stdio config, the `emisar-mcp` install one-liner (`curl -sSL https://emisar.dev/install-mcp.sh | sudo bash`) is documented and the binary is checksum-verified.
- [ ] `EMISAR_API_KEY` placeholder is `emk-...` (never a real key).
- [ ] Tool-name check: confirm Cursor accepts dotted tool names.

**Human-owned:** submit via Cursor's current marketplace intake (PR to their
registry repo or their form — verify which at submission time).

---

## 8. ChatGPT apps / connectors

ChatGPT calls custom MCP connectors **apps**; remote HTTPS MCP only (no stdio).
Flow from `/docs/connect-an-llm`. There are **two distinct ChatGPT integration
paths, and they behave very differently against a dynamic per-account catalog** —
this distinction is the crux the "verify and submit to ChatGPT" work turned on, so
read it before assuming a directory listing is the goal.

#### 8a. Compatibility finding — snapshot vs. dynamic catalog (verified 2026-07-10)

emisar's `tools/list` is **dynamic and per-account** ([§1 Tool surface](#1-canonical-product-facts)):
two operators of the same account can see different tools, and the set shifts with
runner scope and pack versions. That collides with how OpenAI's **public Plugin
directory** publishes an app. Verified against current OpenAI docs:

- **The directory freezes one metadata snapshot for all users.** In the plugin
  submission portal, *"When you scan the app's MCP endpoint … OpenAI stores the
  discovered metadata with that draft version"* while *"tool calls … continue to
  use your live MCP server."* Plugins that contain apps *"use reviewed app metadata
  snapshots."* So the tool **names/schemas/descriptions/annotations** every ChatGPT
  user sees are frozen from whatever tenant was scanned at submission; only tool
  **execution** hits the live per-user endpoint.
- **Dynamic per-user tool lists aren't supported** by the submission flow — it wants
  a single snapshot that *"represents your app's contract."*
- **Per-account divergence is treated as a breaking change.** *"Removing or renaming
  a tool, making a schema incompatible … can break the current version as soon as
  the server change deploys."* For emisar the live catalog legitimately differs from
  the snapshot for **every account except the one scanned** — the reviewer tenant's
  `showcase.*` tools don't exist for a real customer, and that customer's real
  runner actions aren't in the snapshot. The model would be told it can call tools
  the live endpoint refuses, and would never learn the account's actual tools.

**Conclusion:** a public Plugin-directory listing built from any single reviewer
snapshot is **incomplete, misleading, and unusable for other accounts** — the exact
condition the task says must be **blocked with a decision, not worked around by
silently changing the catalog or shipping a broken app**. The product decision
(pursue the directory via a static ChatGPT-facing tool surface, or support ChatGPT
only via the per-user path below) is captured in this task's `decision.md`
(`.agent/tasks/…/2026-07-09-verify-and-submit-emisar-to-the-chatgpt-plugins`).
**Do not weaken account isolation or the per-account catalog to fit the directory
scanner.**

#### 8b. Supported path — per-user Developer Mode custom connector (compatible)

The **Developer Mode custom connector** path is fully compatible and is the
integration `/docs/connect-an-llm` documents. Each operator connects the remote MCP
URL over OAuth **as themselves**; ChatGPT fetches that operator's `tools/list`
**live** and it is **refreshable** (*"custom connectors are scoped to your
account"*; *"whenever you change your tools list or descriptions, refresh your MCP
server's metadata in ChatGPT"*). No directory submission is required, so the
per-account catalog, approval, and audit posture are preserved end to end.

**Create-connector fields**

| Field | Value |
|---|---|
| Connector name | `emisar` |
| Description | `Run approved infrastructure actions on my fleet — gated, approved, and audited.` |
| Connector URL | `https://emisar.dev/api/mcp/rpc` |
| Authentication | **OAuth** (if ChatGPT shows a token/header field, switch back to OAuth) |
| Privacy policy | `https://emisar.dev/privacy` |
| Support | `support@emisar.dev` |

**Field-by-field checklist**

- [ ] Enable Developer mode once (Settings → Apps & Connectors → Advanced).
- [ ] Create → OAuth → emisar sign-in → Authorize succeeds (human-owned live test).
- [ ] Added to a **new chat** via **+ → More → emisar** (settings-only visibility ≠ usable).
- [ ] After any tool-metadata change, use **Refresh** in the connector settings before re-testing.
- [ ] Golden + negative prompts ([§4](#4-golden--negative-prompts)) run green.
- [ ] Tool-name check: the Apps-SDK MCP path uses dotted names in its own docs (its
  example tool is `kanban.move_task`), so the dotted `action_id` names are expected
  to pass here — but OpenAI's **Chat Completions** function-name rule is
  `^[a-zA-Z0-9_-]{1,64}$` (no `.`), and the two have been observed to diverge, so
  **confirm dotted names live on the MCP connector before relying on them**; the
  reviewer tenant's `showcase.*` names are ≤ 24 chars regardless. If ChatGPT rejects
  a `.`, that's a real finding to raise, not something to hide.

**Human-owned (per-user path):** none of the above is done from this repo — a human
runs the live OAuth + golden/negative pass from a real ChatGPT account against the
deployed endpoint.

**Human-owned (directory path):** blocked pending the product decision in this
task's `decision.md` — do not submit a snapshot that misrepresents other accounts.

---

## 9. Tool metadata inventory

The exact `tools/list` output is **per-account and per-key**, so it must be
captured against the reviewer tenant at submission time, not hard-coded here.
Capture it with the reviewer key (this reads only; it dispatches nothing):

```sh
# Reviewer key from the ops vault — never paste it into a file or a vendor form.
curl -s -X POST https://emisar.dev/api/mcp/rpc \
  -H "Authorization: Bearer $EMISAR_REVIEWER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | jq '{count: (.result.tools|length),
         names: [.result.tools[].name],
         longest: ([.result.tools[].name]|max_by(length)),
         longest_len: ([.result.tools[].name]|map(length)|max),
         annotations: [.result.tools[] | {name, annotations}]}'
```

**Expected shape for the showcase-only reviewer tenant** (one sandbox runner with
the `showcase` pack): **11 tools** — 5 action tools
(`showcase.every_arg_type`, `showcase.json_output`, `showcase.opts_envelope`,
`showcase.path_validation`, `showcase.script_action`) + the 6 synthetic tools.
Longest name: `showcase.path_validation` (24 chars). Paste the real captured JSON
into the submission record for each platform; do not trust this expectation blindly
— pack versions and runner scope shift the list.

### Static server-side guarantees (verified in source 2026-07-10)

These hold for **every** tenant, independent of the live `tools/list` capture
above — they are enforced in the MCP tool builder
(`apps/emisar_web/lib/emisar_web/controllers/mcp/{service.ex,content_blocks.ex,tool_metadata.ex}`)
and the catalog ingest changeset (`apps/emisar/lib/emisar/catalog/runner_action/changeset.ex`).
They are what a directory reviewer's "every tool has a title / accurate risk
annotation / bounded output" checks probe, so certify them once here:

- **Every tool carries a non-empty `title`.** Action tools take the action's own
  title (`ToolMetadata.group_title/1`, deterministic across runner ordering,
  falling back to the always-present `action_id`); the six synthetic tools carry
  fixed titles (`Wait for a run to finish`, `List runbooks`, `Get a runbook`,
  `Execute a runbook`, `Create a runbook draft`, `Recent runs`).
- **`title` is length-bounded** — 255 chars at catalog ingest
  (`@max_title_length`); synthetic titles are ≤ 24 chars.
- **Annotations are risk-derived and worst-case for a group.** `readOnlyHint` is
  true only when a `low`-risk action has no side effects; `destructiveHint` is
  true for `high`/`critical`. For an action advertised by several runners the
  group is annotated at its **worst** variant (read-only only if *every* variant
  is read-only; destructive if *any* is high/critical), so a critical variant can
  never ride under a read-only hint. `execute_runbook` is `destructive`+open-world;
  the read-only synthetic tools (`wait_for_run`, `list_runbooks`, `get_runbook`,
  `recent_runs`) are `readOnlyHint: true`.
- **Every tool is stamped** with the OAuth `securitySchemes` marker
  (`type: oauth2`, scopes `["mcp"]`) via `ToolMetadata.auth_required/1`.

**Certification caveat — the tool `name` is not length-capped server-side.** The
action-tool `name` is the `action_id` verbatim, bounded only by the runner socket
frame (~1 MB), **not** by a `validate_length` (unlike `title`/`description`). Real
`action_id`s come from trusted, hash-verified packs in the `<namespace>.<name>`
form and are short (the whole catalog is ≤ ~30 chars); the reviewer tenant's
showcase names are ≤ 24 chars. But a platform that enforces a tool-name length or
charset limit (Claude/OpenAI's `^[a-zA-Z0-9_-]{1,64}$`) must still be checked per
the platform's **tool-name check** line — this static guarantee does *not* cover
the dotted `.` or a hypothetical over-length pack id. A server-side `action_id`
length/format bound is tracked in the root `BACKLOG.md`.

---

## 10. Public URL verification

Every public doc/privacy/trust/support/setup URL and the OAuth discovery endpoints
were probed live on **2026-07-10** — all returned `200` (support is an email, not a
page):

```
200  https://emisar.dev/
200  https://emisar.dev/docs/connect-an-llm
200  https://emisar.dev/docs/mcp-reference
200  https://emisar.dev/privacy
200  https://emisar.dev/security
200  https://emisar.dev/trust
200  https://emisar.dev/pricing
200  https://emisar.dev/docs
200  https://emisar.dev/dpa
200  https://emisar.dev/terms
200  https://emisar.dev/.well-known/oauth-protected-resource
200  https://emisar.dev/.well-known/oauth-authorization-server
401  https://emisar.dev/api/mcp/rpc   (expected: unauthenticated → RFC 9728 challenge)
```

Re-run right before any submission:

```sh
for p in / /docs/connect-an-llm /docs/mcp-reference /privacy /security /trust \
         /pricing /docs /dpa /terms \
         /.well-known/oauth-protected-resource /.well-known/oauth-authorization-server; do
  printf '%s  https://emisar.dev%s\n' "$(curl -s -o /dev/null -w '%{http_code}' "https://emisar.dev$p")" "$p"
done
```

---

## 11. Human-owned steps remaining

These require a real vendor portal session, live product access, a browser, or the
secret store — none are done from this repo. All are operator execution steps
**except** the ChatGPT *directory* row, which is blocked on a product decision (see
[§8a](#8-chatgpt-apps--connectors) and the task `decision.md`).

| Platform | Human-owned steps |
|---|---|
| **MCP Registry** | Choose namespace; verify ownership (GitHub OAuth or DNS TXT); `mcp-publisher publish`; confirm the record is live. |
| **Claude** | Complete Anthropic's directory intake + security review; live DCR test from a clean account; deliver reviewer creds out-of-band. |
| **Cursor** | Confirm current intake mechanism (PR vs form); live OAuth test from a clean Cursor install; submit. |
| **ChatGPT (per-user path)** | Live OAuth + golden/negative pass from a real ChatGPT account in Developer Mode against the deployed endpoint; confirm dotted tool names are accepted (or raise it). Fully supported ([§8b](#8-chatgpt-apps--connectors)). |
| **ChatGPT (directory listing)** | **Blocked on a product decision** — the directory freezes one metadata snapshot that can't represent the dynamic per-account catalog ([§8a](#8-chatgpt-apps--connectors)). Do not submit until the decision resolves to a static ChatGPT-facing tool surface. |
| **All** | Re-diff each vendor form against this kit (freshness rule); capture the real `tools/list` per [§9](#9-tool-metadata-inventory); capture the screenshots + provision the reviewer tenant per [reviewer-tenant.md](reviewer-tenant.md). |
