# portal — TASKS

The work queue. `[ ]` todo · `[w]` claimed/WIP · `[x]` done + gated-green + committed · 
`[B]` blocked (a `[B]` **must** have a matching entry in `PENDING_DECISIONS.md`). The 
loop takes the first `[ ]`. Contract, work loop, and Definition of Done: root `AGENTS.md` →
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

- [ ] Rework the Policies management to make them UX friendly: remove "Setting low to Deny forces the rest to Deny too — there's no scenario where blocking a safe action while letting a critical one through makes sense."; The "Scope" section needs an overhaul. It should be a live-editable form like "Per-action overrides" where you can add a new ruleset, then select either a runner or a group, and add overrides for it. It all should be clean, usable and easy to understand

- [x] _(repo-wide)_ Codex command-wrappers — spike the `.codex/prompts/` path +
      format, then add thin wrappers that point at `AGENTS.md` / `.agent/rules`
      (no knowledge duplication). The AGENTS.md foundation already makes Codex read
      instructions + state; this is only the slash-command convenience layer.
- [x] _(repo-wide)_ Thin the portal skills into wrappers over `AGENTS.md` +
      `.agent/rules` instead of restating rules inline, so a Codex prompt can point
      at the same knowledge.
