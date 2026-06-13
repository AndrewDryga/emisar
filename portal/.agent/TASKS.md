# portal — TASKS

The work queue. `[ ]` todo · `[x]` done + gated-green + committed · `[B]` blocked
(a `[B]` **must** have a matching entry in `PENDING_DECISIONS.md`). The loop takes
the first `[ ]`. Contract, work loop, and Definition of Done: root `AGENTS.md` →
"The `.agent/` working state". Gate for this project: `portal/AGENTS.md` → IL-20.
Completed work before 2026-06-12 is in `ARCHIVE.md`; `git log` is the record after.

## Active

- [x] Fix the `work` and `new-context` skills — they still reference the retired
      "sanity grep" enforcement model. Update to the current Credo model (custom
      `Emisar.Checks.*` AST checks, `mix credo`). Found during the AGENTS.md rename
      sweep; the rules themselves are correct, only the enforcement wording is stale.
      _(Also swept `context-fn` — same shape — and folded `mix credo` into all three
      IL-20 gate commands. Left `iron-review`'s grep methodology + the deliberately
      abbreviated frontend/deploy/document/testing gates alone.)_
_(Codex command-wrappers and portal-skill-thinning moved to `BACKLOG.md` — they're
deferred, repo-wide follow-ups, not part of an active batch.)_
