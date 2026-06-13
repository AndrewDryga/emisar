---
name: batch
description: Drain a project's .agent/TASKS.md queue autonomously and run-to-completion — claim each `[ ]`, do it, gate it green, COMMIT IT ON ITS OWN, tick `[x]` — without quitting early. Arms the Stop-hook sentinel for the run and disarms it when the queue is clear. Use to "work all the tasks" / drain a backlog / run an unattended batch over a project's queue.
effort: max
argument-hint: "[project: portal|runner|mcp|packs — default: every project with open tasks]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# /batch — drain the TASKS queue, one commit per item

Runs the work loop (root `AGENTS.md` → "The work loop") to completion with the Stop hook
armed, so it can't quit while work remains. **Scope:** the `$1` project's
`.agent/TASKS.md`, or every project's queue if no arg. Each resolved item is its **own
commit** — never a batched end-of-run commit.

## 1. Arm
- `touch .claude/.batch-active` — arms `stop-guard.sh`: until you disarm, trying to stop
  while any `- [ ]` remains is blocked. (The sentinel is git-ignored.)
- Read the project's `AGENTS.md` in full (the gate + the laws you're about to obey), then
  announce which queue(s) you're draining and the open-`[ ]` count.

## 2. The loop — repeat until no `- [ ]` remains
For the first `- [ ]` in the queue:
1. **Claim it** — flip `- [ ]` → `- [w]` with an Edit (fails safe if another agent changed
   the file first; on a collision, re-read and take the next `- [ ]`). **Skip any `- [w]`** —
   that's a parallel agent's live claim, not yours to take.
2. **Do it** — wear the hats; obey the project's `AGENTS.md`. If the item spans more than one
   file/context, `/plan` it first.
3. **Gate it green** — run the project's exact gate (`<project>/AGENTS.md` → "The gate" / IL-20).
   Fix until clean. **No green, no commit.**
4. **Commit it on its own** — ONE focused commit for THIS item, with an **explicit pathspec**
   naming only the files this task changed:

   ```
   git commit -F - -- path/one path/two <<'MSG'
   <area>: <what changed> (<task ref>)

   <why, 1–3 lines>
   MSG
   ```

   **Never `git add -A` or a bare `git commit`** — a parallel agent may have unrelated work
   staged in the shared index; an explicit pathspec commits only yours. (Gotcha: `git commit -- <path>`
   takes the *worktree* copy, so it re-adds a file you `git rm --cached`'d — for a deletion,
   `git rm` it then bare-commit guarded to your paths.)
5. **Log it** — append a one-line *what + why* to `<project>/.agent/LOG.md`.
6. **Tick it** — flip `- [w]` → `- [x]`. Next `- [ ]`.

- **Blocked?** Mark `- [B]` + add a `PENDING_DECISIONS.md` entry (decision · options ·
  recommendation), then move on — `[B]` doesn't block the Stop hook.
- **Spot unrelated work?** Jot it in `BACKLOG.md` and stay on the current item.
- **Never** hold a `- [w]` you're not actively working — finish it, `[B]` it, or revert to `- [ ]`.

## 3. Finish
- When no `- [ ]` remains: **completeness pass** — re-verify every `- [x]` you resolved this
  run against `git log` (each should be its own commit). Eyeball passes miss work.
- **Disarm** — `rm -f .claude/.batch-active`.
- Report: items done (with commit SHAs), items `[B]`'d (+ why), anything filed to `BACKLOG`.

## Aborting / resuming
An interrupted batch **deliberately** leaves the sentinel in place, so the next session
resumes the queue (the Stop hook keeps it honest). To stop a batch for real:
`rm .claude/.batch-active`. Don't auto-reclaim a stale `- [w]` unless you're sure it's
orphaned (an interrupted session), not a live parallel claim.
