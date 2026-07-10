# Publishing the emisar Cursor plugin

This directory is a **self-contained Cursor Marketplace plugin**, ready to become
the root of a small dedicated public Git repository. The engineering (manifest,
MCP config, docs, license, icon) is done and committed in the monorepo; the steps
below are **human-owned** — they need a real Cursor install, live OAuth, and the
Cursor publisher portal, none of which run from CI or an agent box.

Field-level listing copy (name, tagline, description, category, URLs, data
handling, golden/negative prompts, reviewer tenant) is not duplicated here — it
lives in the shared kit: [`../mcp-catalog-submission.md`](../mcp-catalog-submission.md)
(§2, §4, §7) and [`../reviewer-tenant.md`](../reviewer-tenant.md).

## What's in this directory

```
cursor-plugin/
├── .cursor-plugin/plugin.json   # plugin manifest (name required; rest is metadata)
├── mcp.json                     # one remote MCP server, OAuth via DCR
├── assets/logo.svg              # square emisar mark (390×390)
├── README.md                    # user-facing install + safety model
├── CHANGELOG.md                 # SemVer history
├── LICENSE                      # Apache-2.0
└── PUBLISHING.md                # this file
```

Design choices, and why:

- **`mcp.json` is a bare remote `url`** (`https://emisar.dev/api/mcp/rpc`) with no
  `auth` block. Cursor treats a remote streamable-http server without static
  credentials as an OAuth client and runs Dynamic Client Registration
  automatically — so there is **no static bearer token** in the plugin, matching
  emisar's DCR posture (kit §Authentication). A root `mcp.json` is auto-detected,
  so `plugin.json` deliberately omits an `mcpServers` field.
- **No rules / skills / agents / hooks / subagents.** The task allows a narrowly
  scoped incident-investigation skill *only if live testing shows it materially
  helps* — that can't be judged from a box without Cursor, so nothing is bundled.
  Add one later only with evidence, and keep it read-only-diagnostics scoped and
  verified against the real per-account tool catalog.
- **Apache-2.0**, not the repo's BSL. The plugin is an open-source integration
  shim like `runner/`, `mcp/`, and `packs/` — a config pointing at the hosted
  service, meant to be freely installable.

## Verified against the current Cursor spec (2026-07-10)

Re-diff before submitting (the "freshness rule"):

- Plugin spec & reference: <https://cursor.com/docs/reference/plugins>,
  <https://cursor.com/docs/plugins>, <https://github.com/cursor/plugins>
- Remote MCP config: <https://cursor.com/docs/context/mcp> — a remote server is
  `{"url": "…"}`; static OAuth would add an `auth` object (we don't — we use DCR).
- Publisher form: <https://cursor.com/marketplace/publish>

`plugin.json`: only `name` is required (kebab-case, alphanumerics/hyphens/periods,
starts and ends alphanumeric). Everything else here — `version`, `description`,
`author`, `homepage`, `repository`, `license`, `keywords`, `logo` — is optional
metadata the marketplace surfaces.

## Human-owned steps

1. **Create the public repo.** Copy this directory to the **root** of a new public
   repo (the placeholder in `plugin.json`/`README.md` is
   `https://github.com/andrewdryga/emisar-cursor-plugin` — create it, or pick the
   real name and update `repository`/`homepage` + the README links to match). The
   monorepo can't be submitted directly because it isn't rooted as a Cursor plugin.
   Tag `v0.1.0`.
2. **Validate + install locally.** Run Cursor's plugin validation against the repo,
   then load the plugin locally in a current Cursor build.
3. **Test OAuth + the golden/negative flows** against the reviewer tenant
   (`../reviewer-tenant.md`): read-only diagnostics (allow), approval-required
   remediation (pending → human approve), a policy denial, and audit attribution
   — the G1/G2/G3/N1 prompts in kit §4. Confirm Cursor accepts the reviewer
   tenant's dotted tool names (`showcase.*`); if it rejects a `.` in a tool name,
   that's a real finding to raise, not to hide.
4. **Submit** the public repo at <https://cursor.com/marketplace/publish>; accept
   the publisher terms; **record the submission reference** (add it to this file
   or the ops record).
5. **Address review feedback, publish after approval, verify** a clean install
   from the public Marketplace, and note the version-bump/update process
   (bump `plugin.json` `version` + a `CHANGELOG.md` entry, re-tag, resubmit).
