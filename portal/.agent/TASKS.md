# portal — TASKS

The work queue. `[ ]` todo · `[x]` done + gated-green + committed · `[B]` blocked
(a `[B]` **must** have a matching entry in `PENDING_DECISIONS.md`). The loop takes
the first `[ ]`. Contract, work loop, and Definition of Done: root `AGENTS.md` →
"The `.agent/` working state". Gate for this project: `portal/AGENTS.md` → IL-20.
Completed work before 2026-06-12 is in `ARCHIVE.md`; `git log` is the record after.

## Active

- [ ] Fix the `work` and `new-context` skills — they still reference the retired
      "sanity grep" enforcement model. Update to the current Credo model (custom
      `Emisar.Checks.*` AST checks, `mix credo`). Found during the AGENTS.md rename
      sweep; the rules themselves are correct, only the enforcement wording is stale.
- [ ] _(repo-wide, deferred)_ Codex command-wrappers — spike the `.codex/prompts/`
      path + format, then add thin wrappers that point at `AGENTS.md` / `.agent/rules`
      (no knowledge duplication). The AGENTS.md foundation already makes Codex read
      instructions + state; this is only the slash-command convenience layer.
- [ ] _(repo-wide, deferred)_ Thin the portal skills into wrappers over `AGENTS.md`
      + `.agent/rules` instead of restating rules inline, so a Codex prompt can point
      at the same knowledge.
