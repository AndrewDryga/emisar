# .agent/kb — the self-improving knowledge base

Descriptive operational knowledge an agent needs but the code doesn't obviously carry:
subsystem maps, cross-cutting traps, hard-won gotchas. Sibling of `rules/` — but `rules/`
is NORMATIVE ("do X, not Y") while a card here is DESCRIPTIVE ("here's how X actually
works, and the trap"). A rule may link to a card for background.

## Reading protocol

Read this INDEX at boot; open a card ONLY when your task touches its subsystem. Never
bulk-load the kb into a prompt — the index is the routing table, cards are pulled on
demand (like skills). That scoping is also the safety rail: a card only ever reaches the
prompts of tasks in its own subsystem, so a wrong card can't poison work it doesn't touch.

## You maintain this KB — directly

A self-improving wiki: no inbox, no human gate. When a task teaches you something
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

## Changelog
- <YYYY-MM-DD> — created / what changed (and what you verified it against)
```

## Index

- [coop-box-builds-are-isolated](coop-box-builds-are-isolated.md) — PGHOST=db reaches the sibling postgres; box BEAM/Go builds live under the coop-cache volume (MIX_BUILD_ROOT), never the host's _build; the portal output guard warms deps unscanned
- [oauth-sign-in-return-to](oauth-sign-in-return-to.md) — a protected OAuth GET stores its exact local path in the signed session; magic-link, registration, and SSO sign-in must preserve it through consent
- [oauth-consent-form-action](oauth-consent-form-action.md) — ChatGPT's sandboxed OAuth document needs a consent-only HTTPS form-action source; rejected requests and every other page keep the strict self-only policy
- [runner-enrollment-key-reset](runner-enrollment-key-reset.md) — a changed enrollment key rotates the token while preserving external identity unless the installer explicitly resets generated auth state
- [portal-image-delivery-follows-main](portal-image-delivery-follows-main.md) — every successful main push publishes its exact tested portal image; production planning has no stale-image fallback, and health reports the compiled source revision
