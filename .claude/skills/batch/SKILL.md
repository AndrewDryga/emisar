---
name: batch
description: Drain a project's .agent/TASKS.md queue autonomously and run-to-completion, taking EACH item to a ship-ready bar — claim `[ ]`, build it, gate it green, self-review it against the house rules (portal Iron Laws / runner security posture / pack conventions + the .agent/rules KB) AND every hat (security, UX, marketing, docs, code quality, tests), ITERATE until it's clean, then COMMIT IT ON ITS OWN and tick `[x]` — without quitting early. Arms the Stop-hook sentinel for the run. Use to "work all the tasks" / drain a backlog to a high bar / run an unattended batch.
effort: max
argument-hint: "[project: portal|runner|mcp|packs — default: every project with open tasks]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# /batch — drain the TASKS queue to a ship-ready bar, one commit per item

Runs the work loop (root `AGENTS.md` → "The work loop") to completion with the Stop hook
armed, so it can't quit while work remains. **Scope:** the `$1` project's `.agent/TASKS.md`,
or every project's queue if no arg.

**Be agentic.** Each item is taken to a **ship-ready** bar: built, gated, then *self-reviewed
from every angle it touches and iterated until clean* — and only **then** committed, on its own.
The bar is not "it compiles"; it's "I'd defend this in review from every hat **and it breaks no
house rule.**" **The house rules are the spine of that bar** — the project's rule index (portal
**Iron Laws IL-1…IL-20**; the runner/mcp **security posture + Go house style**; the **pack
conventions**) *and* the worked examples in `<project>/.agent/rules/`. Build *to* them, then
*check the diff against them*. Don't trust your first draft; review it and fix it.

## 1. Arm
- `touch .claude/.batch-active` — arms `stop-guard.sh`: until you disarm, trying to stop while
  any `- [ ]` remains is blocked. (Sentinel is git-ignored.)
- Read the project's `AGENTS.md` in full — the gate **and the rule index** (portal Iron Laws +
  House opinions; runner/mcp security posture + Go house style; pack conventions) — **and every
  `<project>/.agent/rules/*.md`** (the worked-example taste KB). These are the bar you build to,
  not just check against — load them before you touch code. Announce the queue + open-`[ ]` count.
- **Optional `/goal`** — you may set a run goal (`/goal drain <project>'s queue: every item
  house-rule-clean, ship-review-clean and committed; don't stop`) to harden don't-quit-early on
  top of the sentinel, and/or a **per-task `/goal`** for a stubborn item so its
  build→review→iterate cycle runs to completion. Clear it at Finish.

## 2. The loop — for the first `- [ ]`, repeat until none remain
1. **Claim** — flip `- [ ]` → `- [w]` (fail-safe Edit; on collision re-read + take the next).
   **Skip any `- [w]`** — a parallel agent's live claim.
2. **Build** — wear the hats while building; obey the project's `AGENTS.md` laws, match the
   `.agent/rules/` examples and the surrounding style exactly. `/plan` first if it spans more
   than one file/context.
3. **Gate green** — the project's exact gate (`<project>/AGENTS.md` → "The gate" / IL-20). No
   green, no review.
4. **Self-review from every angle it touches** — the agentic core; review your own diff.
   **House rules first — this comes before the hats and is non-negotiable:**
   - **portal/:** `/iron-review` standalone (the dedicated IL-1…IL-20 checker — cite the law
     each finding breaks) **+** the House-opinions index and every `portal/.agent/rules/*.md`.
     Then `/ship-review` (PM · UX · security · frontend · SEO synthesized) **and** `/code-review`
     (correctness bugs).
   - **Go (runner/mcp):** check the diff against the AGENTS.md **Security posture** (the runner's
     Iron-Law equivalent: never-a-shell · validate-everything · pinned pack trust · contained
     paths) **+ Go house style** (slog, `%w` wraps, stdlib table-driven tests, no new deps) + any
     `.agent/rules/`; then `/security-engineer` (it runs commands on hosts) + `/code-review` + the
     gate's vet/staticcheck.
   - **packs:** the `packs/AGENTS.md` conventions (argv-not-shell, bare binary paths, bound args,
     honest risk) + `/security-engineer` (every action is attack surface) + `emisar pack validate`.
   - **then, proportional to what changed:** security (what's the abuse case?), tests (happy +
     denial + cross-account present — a write isn't done without its denial test), docs (is the
     `@doc`/contract honest + updated?), UX (operator-visible? empty/error/loading states),
     marketing/SEO (marketing page? honest, crawlable), code quality (would the maintainer wince?).
5. **Iterate until ready** — fix every blocker the review raised → re-gate → re-review. Loop
   until it comes back clean from **all** relevant angles, **house rules first**. A rule
   violation is never a one-line fix: **sweep the diff for every sibling instance** and fix those
   too; if the review exposed a shape the KB doesn't yet name, record it via the taste pipeline
   (root `AGENTS.md`) in this same commit — a line in the `AGENTS.md` index (+ a `rules/<slug>.md`
   when it needs worked code). Out-of-scope findings go to `BACKLOG.md`, not into this commit.
   **Commit only when you'd ship it from every hat and it breaks no house rule.**
6. **Commit it on its own** — ONE focused commit for THIS item, explicit pathspec naming only
   the files it changed:

   ```
   git commit -F - -- path/one path/two <<'MSG'
   <area>: <what changed> (<task ref>)

   <why, 1–3 lines>
   MSG
   ```

   **Never `git add -A` / bare-commit** — the shared index may hold a parallel agent's work; an
   explicit pathspec commits only yours. (`git commit -- <path>` takes the worktree copy, so for
   a *deletion* `git rm` it then bare-commit guarded to your paths.)
7. **Log + tick** — append a one-line *what + why* (incl. what the review caught + fixed, and any
   rule recorded) to `<project>/.agent/LOG.md`; flip `- [w]` → `- [x]`. **Then** the next `- [ ]`.

- **Blocked?** `- [B]` + a `PENDING_DECISIONS.md` entry (decision · options · recommendation); move on.
- **Spot a mess?** Small, safe cleanup → fix it in place (boy-scout rule, creed #7). Bigger or unrelated → `BACKLOG.md`; stay on the current item.
- **Never** hold a `- [w]` you're not working — finish it, `[B]` it, or revert to `- [ ]`.

## 3. Finish
- No `- [ ]` left: **completeness pass** — re-verify every `- [x]` against `git log` (one commit
  each) and that none shipped with an unaddressed review blocker or a house-rule violation.
- **Disarm** — `rm -f .claude/.batch-active` (and `/goal clear` if you set a run goal).
- Report: items done (SHAs + what the review caught/fixed + any rule recorded), items `[B]`'d (+ why), `BACKLOG` adds.

## Aborting / resuming
An interrupted batch deliberately leaves the sentinel in place so the next session resumes the
queue (the Stop hook keeps it honest). Stop for real: `rm .claude/.batch-active`. Don't
auto-reclaim a stale `- [w]` unless you're sure it's orphaned, not a live parallel claim.
