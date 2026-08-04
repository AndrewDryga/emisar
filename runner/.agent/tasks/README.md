# Tasks

The work queue. **A task is a folder, and its state is which directory it's in:**

- `00_todo/<id>/`         — not started (the loop picks the next from here)
- `10_in_progress/<id>/`  — claimed/active (the loop resumes one of these)
- `50_blocked/<id>/`      — parked on a human decision (NOT picked; has a `decision.md`)
- `99_done/<id>/`         — shipped/archived (never loaded by the loop)

The numeric prefix is just a sort key: it makes a plain `ls .agent/tasks` list the states in
lifecycle order instead of alphabetically (`99_` keeps done last). `coop tasks` prints the
clean names — todo · in_progress · blocked · done.

There's one more directory, off to the side of the lifecycle:

- `xx_backlog/<id>/`      — unscheduled ideas (`xx_` sorts it last; NOT picked by the loop)

The backlog is the **same folder format**, but it lives OUTSIDE the lifecycle: the loop, the
Stop hook, `coop tasks`, and every counter ignore it, so an idea waits there with no nagging.
Manage it with `coop backlog` — `add "<title>"` to capture, `promote <id>` to move it into
`00_todo/` when it's ready (a folder move, not a rewrite), `rm <id>` to drop it. Not-yet-ready
work belongs in the backlog, never in `00_todo/`.

A state change is a folder move — use the commands, not a manual `mv`:
`coop tasks claim <id>` · `block <id>` · `unblock <id>` · `done <id>`.
The directory IS the status; there is no status field to keep in sync. A finished task is
**moved** to `99_done/`, never deleted — agents only move tasks between states. Pruning the
archive is a manual, human step: `coop tasks rm --all-done`.

## A task folder (`<id>` is `YYYY-MM-DD-<slug>`)

    10_in_progress/2026-06-26-egress-fail-closed/
      task.md        REQUIRED — frontmatter + Context / Acceptance / Approach + subtasks
      log.md         append-only journal — what you did and WHY (newest last)
      state.md       overwritten resume snapshot — where you are / the next action
      spec.md        optional — the design, when it outgrows task.md's Approach
      decision.md    the pending decision (present ⇔ task is in 50_blocked/)
      screenshots/   optional — screenshots, the common visual deliverable (git-ignored)
      artifacts/     optional — durable evidence retained with the completed task (git-ignored)
      tmp/           optional — resumable disposable work, removed when the task reaches done

`coop tasks add "<title>"` seeds **task.md + log.md + state.md**, each opening with a short
HTML-comment header that explains the file (so it's self-documenting, yet renders clean once
filled). `coop tasks block <id>` adds **decision.md**. You add `spec.md` yourself (or via
`/spec`) only when the design is substantial. Every file is plain markdown. The templates below
are what those commands write (minus the header).

---

## task.md — the spec (REQUIRED)

A fresh agent must be able to work the task from this file alone: the problem, the bar for
"done", and the plan. Keep the body short; move a big design into `spec.md`. A freshly-added
task is a stub: whoever picks it up replaces every `<…>` placeholder *before* writing code —
that thinking is step one — or `coop tasks block`s it if they can't yet. The generated
header comment says exactly this, so the reminder travels with the task.

**Template:**

    ---
    id: 2026-06-26-<slug>
    title: <one-line outcome>
    labels: []
    updated: <ISO-8601 timestamp>
    ---

    # <one-line outcome>

    **Context:** <the problem, why it matters, and where in the code it lives>
    **Acceptance criteria:** <the gate green + the behaviour/test that proves it's done>
    **Approach:** <the boring plan; when it outgrows ~a screen, move it into spec.md>

    ## Subtasks
    - [ ] <first small, end-to-end, testable step — check off once the gate is green>

**Example:**

    ---
    id: 2026-06-26-egress-fail-closed
    title: COOP_EGRESS fails closed on an unknown value
    labels: [security]
    updated: 2026-06-26T09:00:00Z
    ---

    # COOP_EGRESS fails closed on an unknown value

    **Context:** A typo like `COOP_EGRESS=None` currently grants full network instead of
    going offline (internal/box/egress.go) — a silent fail-open.
    **Acceptance criteria:** `make check` green; a new test asserts an unrecognised value
    maps to offline, and the README documents the allowed values.
    **Approach:** Parse into an enum; default the unknown case to offline; table-test it.

    ## Subtasks
    - [x] enumerate allowed values + default unknown → offline
    - [ ] table test for typo / empty / valid
    - [ ] document the values in README

A subtask is a `- [ ]` line; `[x]` marks it done and `coop tasks` shows the count. Lines inside
fenced code blocks don't count, so you can paste examples freely.

---

## state.md — the resume snapshot

The single most useful file for an unattended loop: each iteration is a fresh agent with no
memory of the last, so this is how a task survives an interruption. **Overwrite the whole file**
at every checkpoint (before a commit, before you pause) — it's a snapshot, not a log. Keep it to
a few lines, and on resume read it first.

**Template:**

    # State — <title>

    **Status:** not started
    **Done so far:** —
    **Next action:** <the very next concrete step>
    **Traps:** <gotchas the next agent must know, or —>

**Example** (mid-task):

    # State — COOP_EGRESS fails closed

    **Status:** in progress — enum landed, writing tests
    **Done so far:** added egressMode enum; unknown → offline; committed (a1b2c3d)
    **Next action:** add the table test for "" and "None", then update the README
    **Traps:** egress is read in TWO places (entrypoint + doctor) — keep them in sync

After the final commit, refresh the same snapshot with `**Status:** complete` and
`**Next action:** none`, preserving the useful summary and traps. Then move the folder to done as
the final filesystem action. Coop enforces those two lifecycle values atomically at completion;
missing or malformed snapshots are repaired to a minimal safe form.

---

## log.md — the working journal

Append-only history of what you did and **why** — the decisions, dead ends, and surprises a
reviewer (or the next agent) needs. Add to the bottom; never rewrite it. This is the durable
"why"; `state.md` is just "where am I now".

**Template:**

    # Log — <title>

**Example:**

    # Log — COOP_EGRESS fails closed

    ## 2026-06-26 — enum over string compare
    - Switched the raw string check to an egressMode enum, so an unknown value has ONE
      home (the default arm) instead of being scattered. Default = offline (fail closed).
    - Dead end: tried defaulting in the caller — too easy to forget at the second call site.

---

## decision.md — a blocked one-way door

A task goes to `50_blocked/` when it hits a choice that's expensive to undo and needs a human.
`coop tasks block <id>` creates this file; the agent fills the question, options, and a
recommendation; **the human resolves it — write the Resolution and run `coop tasks unblock <id>`,
or do both at once with `coop tasks unblock <id> "<answer>"`.**
`coop tasks decisions` lists every open one with its full recommendation.

**Template:**

    # Decision: <question>?

    **Blocks:** this task (`<id>`).

    **The decision:** <what must be chosen, and why it can't be undone cheaply>

    **Options:**
    - **A — <name>:** <consequence>
    - **B — <name>:** <consequence>

    **Recommendation:** <the agent's pick + one line why>

    ---

    **Resolution:** <!-- HUMAN: your answer here, then: coop tasks unblock <id> — or pass it inline -->

**Example** (agent filled, awaiting the human):

    # Decision: store egress mode where?

    **Blocks:** this task (`2026-06-26-egress-fail-closed`).

    **The decision:** Whether the mode is an env var only or also persisted in .agent/config —
    persisting changes the on-disk format (a one-way door for older coop).

    **Options:**
    - **A — env only:** simplest; no format change; set per run.
    - **B — persist in config:** sticky across runs, but old coop can't read the new key.

    **Recommendation:** A — env-only keeps the format stable; revisit if users ask for sticky.

    ---

    **Resolution:** A — go with env-only.    ← human writes this + `coop tasks unblock <id>`, or in one step: `coop tasks unblock <id> "A — env-only"`

---

## spec.md — the design (optional)

For a task whose plan outgrows task.md's **Approach** (more than ~a screen). Put the durable
design here — the shape, the trade-offs, the rejected alternatives — and keep task.md's Approach
to a one-line pointer. Write it with `/spec`. Small tasks don't need one.

## screenshots/ · artifacts/ · tmp/ (optional, git-ignored)

`screenshots/` is the common visual deliverable (a UI change, a before/after). `artifacts/` holds
other durable evidence a reviewer or future maintainer needs: repros, captured data, generated
files. Both remain with the task in `99_done/` until a human prunes the archive.

`tmp/` is the task-local workspace for disposable scratch worktrees, patches, and generated files.
It follows the task through todo, in-progress, and blocked transitions so interrupted work can
resume. Moving the task to done removes `tmp/` automatically before review; promote anything worth
retaining to `artifacts/` first. All three directories are git-ignored, so they never bloat a commit.

---

## Rules

- One task = one outcome = one commit (the code change). The `99_done/` move itself is local — the queue is gitignored.
- Claim with `coop tasks claim <id>` BEFORE you start.
- Blocked? `coop tasks block <id>`, then fill in `50_blocked/<id>/decision.md`.
- Finish with `coop tasks done <id>` — the task is **moved** to `99_done/`, never deleted; Coop
  finalizes its lifecycle fields and removes only disposable `tmp/`. A state write or cleanup
  failure fails completion loudly and an already-done retry finishes the work.
- Pruning the archive is a manual, human step: `coop tasks rm --all-done` (or
  `coop tasks rm <id>` for one). The loop and `/sweep` never do this.
- A todo task must NOT carry a `decision.md` (that means it's blocked); a blocked one MUST.
- Never add a `status:` field — the directory IS the status. `coop tasks lint` checks this.
- Counts / subtask progress / the blocked list are DERIVED — `coop tasks`,
  `coop tasks decisions`. Never hand-maintain them.

Run `coop tasks` to list the queue, `coop tasks add "<title>"` to scaffold a task.
