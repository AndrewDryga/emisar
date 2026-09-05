# Task file templates

Read [the task runbook](../kb/runbooks/agent-tasks.md) for scope, claiming,
verification, commits, completion, decisions, and recovery. The root AGENTS.md
owns authority and current-checkout rules. This file describes working-state files.

Use `coop tasks add --project root "<title>"` or the owning project to scaffold
task.md, log.md, and state.md. Replace placeholders before implementation.
Keep the generated `**Context:**`, `**Acceptance criteria:**`, and
`**Approach:**` labels: Coop's linter recognizes that exact shape. Missing facts
call for investigation; use a blocked task only for a genuine human decision.

## task.md

```markdown
---
id: YYYY-MM-DD-<slug>
title: <one-line outcome>
labels: []
updated: <ISO-8601 timestamp>
---

# <one-line outcome>

**Context:** <the problem, why it matters, and the relevant source>

**Acceptance criteria:** <complete requested behavior, tests, and canonical gate>

**Approach:** <implementation and verification; link spec.md for substantial design>

## Subtasks

- [ ] <coherent, testable step>
```

The folder is the state, not a frontmatter status field or checklist.
A fresh agent can recover the task's intent from this specification and its
state/log. Do not silently reduce the user's requested behavior to fill the template.

## state.md

Overwrite the resume snapshot at checkpoints. Read it first on resumption.
Preserve accepted decisions, authority, completed checks, and pending jobs.

```markdown
# State — <title>

**Status:** in progress
**Done so far:** <completed work and verification>
**Next action:** <the exact next action>
**Traps:** <constraints, decisions, pending jobs, or evidence gaps>
```

After the final gate and commit, set `**Status:** complete` and
`**Next action:** none`, retaining the outcome and verification. Then complete
through Coop. Cite task IDs in notes, not commit SHAs: box commits can be re-signed.

## log.md

Append decisions and evidence; do not rewrite earlier entries.

```markdown
# Log — <title>

## YYYY-MM-DD — <decision or checkpoint>

- <What changed and why; evidence, dead ends, and material limitations.>
```

## decision.md

`coop tasks block <id>` creates the decision stub. Fill the human choice,
options, and recommendation. Once the user answers, record their resolution and
use `coop tasks unblock <id>`. Investigation alone is not a reason to block.

## Optional files

- `spec.md` holds a design too large for the Approach; link it from task.md.
- `screenshots/` holds visual evidence, captured after claiming the task.
- `artifacts/` holds other evidence retained with the archived task.
- `tmp/` holds disposable scratch files, not worktrees. Coop removes it on
  completion; promote evidence worth keeping to artifacts/ first.

Task directories and their contents are gitignored. Archive pruning is a separate
human operation. Never delete completed tasks as part of ordinary implementation.
