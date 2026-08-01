# .agent/kb — durable knowledge

The website is the customer and operator documentation. This directory is the
single home for repository knowledge the code does not obviously carry.
Everything under `kb/` is customer-safe and public by default except the
explicit `kb/internal/` subtree:

- Cards directly under `kb/` are DESCRIPTIVE current-system facts: subsystem maps,
  cross-cutting mechanics, and hard-won gotchas.
- Files under `kb/specs/` are NORMATIVE versioned interface and security
  contracts. Machine-readable contracts stay beside the implementation that
  consumes and owns them; a spec links to that source instead of duplicating it.
- Files under `kb/runbooks/` are ordered maintainer procedures for releases,
  incident response, and other infrequent operations.
- Files under `kb/rules/` are NORMATIVE constraints: "do X, not Y," with the reason,
  examples, sweep target, and enforcement.
- `kb/internal/` is the gitignored, non-customer-facing local home for working knowledge and assets:
  campaign materials, positioning drafts, launch plans, private operating notes,
  and similar company context. It is not a secret store: credentials, customer
  data, and sensitive exports never belong in the repository.

Use this decision test:

- If an implementation change makes the document false, update the reference card.
- If the file defines a versioned interface or security contract, put it in
  `specs/`.
- If it tells a maintainer how to perform an operation in order, put it in
  `runbooks/`.
- If an implementation change contradicts the document and should be rejected, write
  that constraint as a rule.
- If both apply, keep the mechanism here, keep the invariant in `rules/`, and link them.

Reference cards describe; they do not prescribe. Policy language such as `must`,
`never`, and `do not` belongs in a rule except when quoted from an external interface.
Published integration manifests, licenses, and package README files stay beside
their artifact in an explicitly tracked subtree under `dist/`; generated
siblings remain ignored. They are product inputs, not repository knowledge.

## Reading protocol

Read this INDEX at boot; open a card, spec, or runbook ONLY when your task
touches its subsystem or operation. Never bulk-load the KB into a prompt — the
index is the routing table, and files are pulled on demand (like skills). That
scoping is also the safety rail: knowledge only reaches prompts for work that
needs it, so a wrong or stale file cannot poison unrelated work.

For marketing, positioning, launches, company operations, or other explicitly
internal work, use `internal/`, creating its local topic directories as needed,
and read only the relevant material already there.
Do not quote, link, publish, or derive customer-facing claims from `internal/`
without explicit review for that destination. Customer-facing knowledge belongs
outside `internal/`; move the final, approved fact or rule rather than making public
surfaces depend on an internal file.

## Maintain descriptive cards directly

A self-improving KB: no inbox, no human gate. When a task teaches you something
non-obvious about a subsystem — a map, a trap, a gotcha the code doesn't carry — CREATE
or UPDATE its card here, in the same commit as the work. Keep it TIDY as it grows: once
a flat list gets long, group cards into per-subsystem subfolders (`portal/`, `runner/`,
`mcp/`, `packs/`, `infra/`) and keep this index current.

The discipline that replaces the human gate is the metadata: every card states when it
was last `updated`, which `subsystem` it maps, and the `sources` (the code) it describes —
so staleness shows at a glance. When you pass through a subsystem, check its cards against
their `sources`; if one has drifted, re-verify and bump it (with a changelog line) or
DELETE it — a card that contradicts the code is worse than no card.

## Card format

One fact per file: frontmatter, a short body (under a screen), and a small changelog so
an outdated card is obvious.

```
---
name: <kebab-case-slug>              # = the filename
description: <one line — judged for relevance straight from this index>
subsystem: <portal | runner | mcp | packs | infra | agent-stack>
sources: [portal/lib/…, runner/pkg/…]  # the code this describes — check drift against it
updated: <YYYY-MM-DD>                # last edit
---

<the fact; cite file:line for load-bearing claims; link related cards with [[name]]>

Related rule: `rules/<domain>-<slug>.md` <!-- link the real rule when applicable -->

## Changelog
- <YYYY-MM-DD> — created / what changed (and what you verified it against)
```

## Index

- [architecture](architecture.md) — runtime components, request flow,
  enforcement ownership, runner lifecycle, and deployment shape
- [coop-box-builds-are-isolated](coop-box-builds-are-isolated.md) — host and box use workspace-local service URLs; box BEAM/Go builds live under the coop-cache volume; the portal output guard warms dependencies unscanned
- [development-keycloak-certificates](development-keycloak-certificates.md) — workspace Keycloak uses a long-lived ignored CA plus a 397-day leaf; macOS trust is fingerprint-specific, automated Chrome is SPKI-scoped, and changed material recreates sidecars
- [oauth-sign-in-return-to](oauth-sign-in-return-to.md) — a protected OAuth GET stores its exact local path in the signed session; magic-link, registration, and SSO preserve it through consent
- [oauth-consent-form-action](oauth-consent-form-action.md) — ChatGPT's sandboxed OAuth document needs a consent-only HTTPS form-action source; rejected requests and every other page keep the strict self-only policy
- [runner-enrollment-key-rotation](runner-enrollment-key-rotation.md) — a changed enrollment key re-registers the configured id or hostname and replaces the cached token
- [portal-image-delivery-follows-main](portal-image-delivery-follows-main.md) — every successful main push publishes its exact tested portal image; production planning has no stale-image fallback, and health reports the embedded source revision

### Specifications

- [compatibility](specs/compatibility.md) — version policy, surfaces frozen at
  1.0, and the deprecation process
- [MCP API](specs/mcp-api.md) — the implemented MCP tool and response contract;
  its normative machine-readable schema is owned by
  `portal/apps/emisar_web/priv/mcp/api-schemas.json`
- [security model](specs/security-model.md) — guarantees, trust boundaries,
  threats, and limitations
- [signed dispatch](specs/signed-dispatch.md) — client-attested execution
  contract, operation, and refusal semantics
- [runner wire protocol](specs/wire-protocol.md) — portal-runner frames,
  lifecycle, replay, and limits

### Runbooks

- [key-compromise response](runbooks/key-compromise.md) — containment and
  rotation procedures by credential class
- [release](runbooks/release.md) — canonical product and component release
  procedure

Normative rules are indexed by the relevant root or project `AGENTS.md` and live
under that project's `kb/rules/`.
- [shared-write-control-bytes-with-printf](rules/shared-write-control-bytes-with-printf.md) — produce ESC/NUL via printf and verify with od -c; raw bytes in edits/heredocs fail silently
