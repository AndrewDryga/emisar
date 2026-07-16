---
name: workflow-sweep
description: Drain a project's .agent/tasks/ queue autonomously and run-to-completion, taking EACH task to a ship-ready bar — `coop tasks claim` a 00_todo/ task, build it, gate it green, self-review it against the house rules (portal Iron Laws / runner security posture / pack conventions + the .agent/rules KB) AND every hat (security, UX, marketing, docs, code quality, tests), ITERATE until it's clean, then COMMIT IT ON ITS OWN and `coop tasks done` — without quitting early. A Stop hook scoped to this skill blocks quitting while any task is actionable. Use to "work all the tasks" / drain a backlog to a high bar / run an unattended sweep.
effort: max
argument-hint: "[project: portal|runner|mcp|packs — default: every project with open tasks]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
hooks:
  Stop:
    - hooks:
        - type: command
          command: 'bash "$CLAUDE_PROJECT_DIR/.claude/skills/workflow-sweep/queue-guard.sh"'
---

# /workflow-sweep — drain the tasks queue to a ship-ready bar, one commit per task

Runs the work loop (root `AGENTS.md` → "The work loop") to completion with the Stop hook
armed, so it can't quit while work remains. **Scope:** the `$1` project's `.agent/tasks/`,
or every project's queue if no arg.

**Be agentic.** Each task is taken to a **ship-ready** bar: built, gated, then *self-reviewed
from every angle it touches and iterated until clean* — and only **then** committed, on its own.
The bar is not "it compiles"; it's "I'd defend this in review from every hat **and it breaks no
house rule.**" **The house rules are the spine of that bar** — the project's rule index (portal
**Iron Laws IL-1…IL-20**; the runner/mcp **security posture + Go house style**; the **pack
conventions**) *and* the worked examples in `<project>/.agent/rules/`. Build *to* them, then
*check the diff against them*. Don't trust your first draft; review it and fix it.

## 1. Arm
- The Stop hook is already armed: it's declared in this skill's frontmatter, scoped to the
  skill's lifetime, so while `/workflow-sweep` is active any Stop attempt is blocked until
  every `00_todo/`+`10_in_progress/` task is finished or blocked. Nothing to touch — no
  sentinel file. (It releases automatically when the skill ends.)
- Read the project's `AGENTS.md` in full — the gate **and the rule index** (portal Iron Laws +
  House opinions; runner/mcp security posture + Go house style; pack conventions) — **and every
  `<project>/.agent/rules/*.md`** (the worked-example taste KB). These are the bar you build to,
  not just check against — load them before you touch code. (You'll announce the queue after the tidy step — next.)
- **Optional `/goal`** — you may set a run goal (`/goal drain <project>'s queue: every task
  house-rule-clean, ship-review-clean and committed; don't stop`) to harden don't-quit-early on
  top of the scoped hook, and/or a **per-task `/goal`** for a stubborn item so its
  build→review→iterate cycle runs to completion. Clear it at Finish.

## 2. Tidy the working state (before the first task)
Start clean — never work around stale state. For each project in scope, reconcile its
`.agent/` files. They're local + git-ignored, so this is housekeeping, not commits; use
fail-safe edits (re-read on collision — a parallel agent may be touching the same file).

- **Done tasks need no pruning.** `coop tasks done` already moved each finished task to
  `99_done/`; the done record lives there + in git (`git log`), not the live queue. If you spot
  a task still in `10_in_progress/` whose work is backed by a commit, finish closing it out
  (`coop tasks done <id>`); a claimed task with **no** matching commit isn't verifiably done —
  leave it and surface it for triage.
- **Unblock resolved decisions.** For each `50_blocked/` task whose `decision.md` now carries a
  human resolution, `coop tasks unblock <id>` (it returns to the queue) and fold the decision
  into its `task.md`. **Never resolve one yourself** — only a human-answered `decision.md`
  unblocks (that's the whole point of a blocked task).
- **Reclaim only *certainly* orphaned claims.** A `10_in_progress/` task left by a dead prior
  session → move it back to `00_todo/` (`coop tasks` / a folder move). Leave any
  `10_in_progress/` task that could be a live parallel claim (you run Claude + Codex at once);
  when unsure, don't touch it.
- Leave the backlog drawer (`tasks/xx_backlog/`, via `coop backlog`) alone — a deliberate
  holding area for the big/not-yet-ready (and founder-approval ideas), not trash. The sweep
  works `00_todo/` only; only a human promotes drawer items.

Now **announce the cleaned queue**: open `00_todo/` count, anything unblocked, anything surfaced.

## 3. The loop — for the first `00_todo/` task, repeat until none remain
1. **Claim** — `coop tasks claim <id>` (moves it `00_todo/` → `10_in_progress/`; on collision
   take the next todo task). **Skip any `10_in_progress/` task** — a parallel agent's live claim.
2. **Build** — wear the hats while building; obey the project's `AGENTS.md` laws, match the
   `.agent/rules/` examples and the surrounding style exactly. `/workflow-spec` first if it spans more
   than one file/context.
3. **Gate green** — the project's exact gate (`<project>/AGENTS.md` → "The gate" / IL-20). No
   green, no review.
4. **Self-review from every angle it touches** — the agentic core; review your own diff.
   **House rules first — this comes before the hats and is non-negotiable:**
   - **portal/:** `/elixir-iron-review` standalone (the dedicated IL-1…IL-20 checker — cite the law
     each finding breaks) **+** the House-opinions index and every `portal/.agent/rules/*.md`.
     Then `/review-ship` (PM · UX · security · frontend · SEO synthesized); use `/review-board`
     when correctness risk spans multiple surfaces, and inspect touched callers/tests directly.
   - **Go (runner/mcp):** check the diff against the AGENTS.md **Security posture** (the runner's
     security equivalent: no cloud/LLM-controlled shell · validate-everything · pinned pack trust · contained
     paths) **+ Go house style** (slog, `%w` wraps, stdlib table-driven tests, no new deps) + any
     `.agent/rules/`; then `/security-engineer` (it runs commands on hosts) + `/review-board` when
     the change warrants a multi-hat pass + the gate's vet check.
   - **packs:** the `packs/AGENTS.md` conventions (pack-authored argv or bounded fixed-shell programs, bare binary paths, bound args,
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
   when it needs worked code). Out-of-scope findings go to the queue (`coop tasks add`) or the
   backlog drawer (`coop backlog add`), not into this commit.
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
7. **Log + done** — append a one-line *what + why* (incl. what the review caught + fixed, and any
   rule recorded) to the task's own `log.md`, overwrite its `state.md` with the final snapshot;
   `coop tasks done <id>` (moves it to `99_done/`). **Then** the next `00_todo/` task.

- **Blocked?** `coop tasks block <id>` and fill its `decision.md` (decision · options · recommendation); move on.
- **Spot a mess?** Small, safe cleanup → fix it in place (boy-scout rule, creed #7). Bigger or unrelated → `coop tasks add` (simple and ready) or `coop backlog add` (big/unscoped); stay on the current task.
- **Never** hold a `10_in_progress/` task you're not working — finish it, `coop tasks block` it, or move it back to `00_todo/`.

## 4. Finish
- No `00_todo/` task left: **completeness pass** — re-verify every `99_done/` task against
  `git log` (one commit each) and that none shipped with an unaddressed review blocker or a
  house-rule violation.
- **Wind down** — `/goal clear` if you set a run goal. The scoped Stop hook releases on its own
  when the skill ends; there is no sentinel to remove.
- Report: tasks done (task ids + what the review caught/fixed + any rule recorded), tasks blocked (+ why), queue/backlog adds.

## Aborting / resuming
The guard only holds while the skill is active, and it reads live queue state — so to stop for
real, finish or `coop tasks block` the remaining actionable tasks (an interrupted sweep is
resumed by re-invoking `/workflow-sweep`, which re-arms the hook and reads the same queue). Don't
auto-reclaim an orphaned `10_in_progress/` task unless you're sure it's dead, not a live parallel claim.
