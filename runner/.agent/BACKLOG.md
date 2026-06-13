# runner — BACKLOG

Actionable work discovered **outside the current task's scope** — bugs, tech debt,
missing tests, refactors — captured so it's never lost. **Not auto-worked:** the
loop pulls only from `TASKS.md` → `## Active`, and the Stop hook does not scan this
file, so items here never block a batch. Promote one by *moving* it into
`TASKS.md` → `## Active`. See root `AGENTS.md`.

## Items

- **`packs/README.md` inventory is stale.** Headline + table say "59 packs / ~976 actions"; the real catalog is **73 packs / 1,096 actions** (`find packs -mindepth 2 -maxdepth 2 -name pack.yaml` = 73). ~14 packs are missing from the table and the totals are wrong. Rebuild the table from the actual `packs/*/pack.yaml` (per-pack: action count, risk ceiling, auth) and fix both headline counts. Pre-existing — the shell-pack commit only bumped 58→59 on an already-wrong base; surfaced during the packs→top-level move (2026-06-13).
