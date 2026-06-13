---
name: work
description: Execute an approved plan step-by-step in portal/, with a compile/format/test gate between steps and no scope creep. Use when implementing a planned change, working through a checklist of steps, or the user says "go"/"implement it"/"do the plan". Stops and reports on the first red gate.
effort: high
argument-hint: "[plan, or 'continue']"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Work the plan

Implement one step at a time. The point is a green, reviewable change — not speed.
If there's no plan yet and the change is non-trivial, run `/plan` first.

## The loop (per step)

1. **State the step** in one line so progress is visible (a `TaskUpdate` if a task
   list exists).
2. **Build it in the standard shape.** Use `/new-context` for a new context and
   `/context-fn` for a new function — don't hand-roll shapes that have a skill. The
   module templates are in `portal/AGENTS.md` §1–§5. If you're unsure a function,
   option, or flag exists — yours or a dependency's — `/verify-api` before you write
   it; don't guess (prime directive #7).
3. **Gate before moving on:**
   ```sh
   cd portal && mix compile --warnings-as-errors && mix format
   mix test <the file(s) this step touched>
   ```
   After each portal `.ex`/`.exs` edit, run `mix credo <that file>` from
   `portal/` (~0.6s) — the `Emisar.Checks.*` findings are the law, not a
   nuisance; fix them immediately, never carry them to the gate.
4. **Red gate → stop.** Don't pile the next step on a broken one. Fix it, or report
   the blocker with the error and your read on it. Never edit a test to make a real
   failure pass.

## Rules while working

- **No scope creep.** Build the approved slice. A good idea that wasn't in the plan
  → note it as "later", don't build it now. If the plan turns out wrong, stop and
  re-plan with the user — don't silently redesign.
- **Readable + no bloat (prime directive).** Match the surrounding style. Delete
  dead code you pass. No speculative options/abstractions. Comments say *why*.
- **Tests are part of the step, not a follow-up.** A write isn't done without its
  denial + cross-account tests (§7).
- **Greenfield (IL-11).** Changing a not-yet-shipped migration → edit it in place.
  Replacing code → delete the old, update callers, in this change.

## Finish (IL-20 — verify before claiming done)

```sh
cd portal && mix compile --warnings-as-errors && mix format --check-formatted && mix credo && mix test
```
`mix credo` is the mechanical gate — the `Emisar.Checks.*` AST checks (AGENTS.md →
Enforcement) must report zero. Then **show the output** and give a plain status:
what's done, what's verified, what's left. If something is unverified, say so — don't
say "should work". Offer `/ship-review` before the PR.
