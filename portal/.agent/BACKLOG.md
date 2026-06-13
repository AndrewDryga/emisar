# portal — BACKLOG

Actionable work discovered **outside the current task's scope** — bugs, tech debt,
missing tests, refactors — captured so it's never lost. **Not auto-worked:** the
loop pulls only from `TASKS.md` → `## Active`, and the Stop hook does not scan this
file, so items here never block a batch. Promote one by *moving* it into
`TASKS.md` → `## Active` when you deliberately schedule it. See root `AGENTS.md`.
(Distinct from `IDEAS.md` = product features needing approval; `PENDING_DECISIONS.md`
= needs a human call.)

## Items

- [ ] _(repo-wide)_ Codex command-wrappers — spike the `.codex/prompts/` path +
      format, then add thin wrappers that point at `AGENTS.md` / `.agent/rules`
      (no knowledge duplication). The AGENTS.md foundation already makes Codex read
      instructions + state; this is only the slash-command convenience layer.
- [ ] _(repo-wide)_ Thin the portal skills into wrappers over `AGENTS.md` +
      `.agent/rules` instead of restating rules inline, so a Codex prompt can point
      at the same knowledge.
