# emisar — agent instructions

Emisar is a control plane for gated, audited infrastructure actions. It is a
security product: runner, LLM, operator, and external input crosses a trust boundary.
This is the canonical manual; CLAUDE.md and GEMINI.md are symlinks.

## Scope and authority

The user's request and accepted decisions define the deliverable. Complete all
authorized work; make routine implementation choices without another approval.
Questions, diagnoses, and reviews call for an assessment unless a change was also
requested. Planning-only requests end with the plan. Queue draining applies only
to an explicitly requested batch or `coop loop`, never to an unrelated interactive task.

Keep the full requested behavior. Do not silently cut scope to a smaller slice,
expand it with unrelated improvements, or reopen settled decisions. Small cleanup
inside the change is appropriate when it directly supports the requested result.
Record other findings for follow-up; do not automatically work them in this session.

Ask only for a material decision, missing authority, or information only the user
can provide. Complete independent, authorized work first. Existing authorization
persists through skills, handoffs, and compaction. A skill cannot add an approval
requirement that conflicts with the user's explicit instruction. If an instruction
actually prevents completion, link its file, quote the relevant rule, and explain
what remains. Deployment, publication, external messages, and destructive actions
require authority for that action; permission to edit code alone does not grant it.

## Read before editing

1. Read this manual and the touched project's AGENTS.md in full.
2. Read [.agent/kb/README.md](.agent/kb/README.md) for knowledge routing. Search the
   [shared rule index](.agent/kb/rules/README.md) and the project's rule index for
   the task's domain; read matching entries and linked rules before editing.
   Load the relevant material, not every reference.
3. Inspect the working tree. For the current task, read its `state.md` first,
   then `log.md` and `task.md`. Use `coop tasks ls` to find an existing task.
   Never take over another agent's active claim or resume an unrelated todo.

| Project | Responsibility | Manual |
|---|---|---|
| portal | Phoenix control plane: web, MCP, authorization, approvals, audit, billing | [portal/AGENTS.md](portal/AGENTS.md) |
| runner | Go on-host action executor | [runner/AGENTS.md](runner/AGENTS.md) |
| mcp | Go stdio-to-HTTP MCP bridge | [mcp/AGENTS.md](mcp/AGENTS.md) |
| packs | YAML action catalog and behavior fixtures | [packs/AGENTS.md](packs/AGENTS.md) |
| infra | Terraform production stack | [infra/AGENTS.md](infra/AGENTS.md) |

After compaction, retain the active objective, user constraints and authorization,
decisions, completed work and checks, pending jobs, and exact next action. Read
missing or changed instructions and the current task snapshot; do not restart
completed investigation or switch tasks because context was compacted.

## Engineering contracts

- Use the existing, simplest complete shape. Match surrounding code; reuse owned
  components and contexts. No speculative abstractions, dependencies, options,
  feature flags, or compatibility shims.
- Consider product value, operator usability, security, and maintainability in
  proportion to the change. Security review covers trust-boundary changes; a
  mechanical edit does not require a board of reviewers.
- Verify unfamiliar APIs against local code, pinned dependencies, or current
  official documentation before using them. Familiarity is not proof of current
  model names, flags, provider behavior, or remote state.
- Validate hostile input at system boundaries. Preserve authorization, account
  isolation, pack trust, audit, redaction, and denial/abuse coverage.
- Before 1.0, update callers and remove superseded code together. A migration
  production already ran is immutable; add a forward migration. Confirmed-unrun
  migrations are corrected in place. Git history does not prove deployment.
  From 1.0, public compatibility surfaces also follow
  [.agent/kb/specs/compatibility.md](.agent/kb/specs/compatibility.md).
- CI validates; CD publishes the same tested commit and artifacts. Write/OIDC
  permissions and deployment secrets belong in CD, never PR CI. Serialize active
  publication. Manual infrastructure applies use provisional configuration
  versions and saved plans.

## Commands and verification

Start with `./run help`; `./run` is the contributor command for agents, people,
hooks, and CI. Public installer/runner/MCP/packctl interfaces remain separate.

- `./run test <project> ...` gives focused feedback; `./run check ...` gives quick
  or specialized checks. Use direct language tools for diagnosis when useful.
- Finish with `./run gate <project>` for every touched project: portal, runner,
  mcp, packs, infra, or tooling. `./run gate all` covers the repository.
- During implementation, run focused checks after coherent edits. Fix a failure
  before building dependent work on it; investigate and repair within the task.
  An initial red check is not a reason to hand the task back.
- The lead owns the final gate on the reviewed tree. Delegates run focused checks.
  Repeat or broaden verification after changes, failures, or unresolved concerns,
  not solely because a handoff or workflow step occurred.
- Add meaningful behavior/regression tests sized like neighboring tests. Preserve
  required denial and isolation cases. Scratch checks need not become permanent
  tests, and assertions that only restate implementation add no proof.
- Report actual command results. Distinguish edited, tested, committed, pushed,
  deployed, and verified live; never present one as evidence of another.

## Tasks and working state

Read [the task runbook](.agent/kb/runbooks/agent-tasks.md) when claiming, completing,
recovering, or batch-processing tasks, or capturing screenshots. Claim implementation
work through Coop. Done requires green gates, a focused commit with `Coop-Task: <id>`,
finished log.md/state.md, and `coop tasks done <id>`.

Preserve unrelated WIP and stage only task-owned changes. Work in the current checkout;
do not create worktrees. Only one agent writes, gates, or commits here at a time.
Missing evidence is investigation work; blocking requires a human decision.
Disposable screenshots belong to the claimed task. Archive pruning is a separate request.

## Delegation and communication

The [frontier preset](.agent/presets/frontier/preset.yaml) owns model targets and
efforts; [.agent/loop.yaml](.agent/loop.yaml) owns batch stages. Role prompts define
responsibilities, not duplicated model names or assumptions about cost.

Delegate independent, bounded research, review, or mechanical work when the
handoff improves time or quality. Keep useful independent work moving while
advisors run. Assign one writer at a time and review its changes. Use thinker and
critic for high-stakes decisions with the same neutral problem statement; check
the configured providers before claiming independent vendor perspectives.
Outside Coop, use the runtime's available subagents for the same responsibilities.

In a Coop box, finish or explicitly terminate owned jobs before ending the turn:
ending the turn destroys the box. Await long-running commands in the same turn;
asynchronous work is useful only while its owning session remains alive.

Give a short initial update, then concise findings and next checks during long
work. Ground progress claims in this session's evidence. The final answer stands
alone: outcome first, material validation and limitations after. Use plain prose,
with lists or tables when they improve clarity.

## Knowledge, corrections, and skills

`AGENTS.md` and `.agent/` are tool-neutral. Shared contributor skills live in
`.claude/skills/`; `.codex/skills` and `.gemini/skills` link to that directory.
Use the relevant skill when it improves this task; read it before applying it.
Public customer skills under `skills/` are a separate, portable product surface.

Keep durable knowledge in the KB. Tracked KB material is customer-safe; internal
company material belongs in gitignored `kb/internal/`, never secrets/customer data.
Tasks, decisions, and local evidence are working state, not committed product docs.

When a correction establishes a reusable rule, update its existing owner or add
a domain-prefixed rule and index entry. Preserve explicit exceptions and scope.
Fix matching instances within the task; queue a larger sweep separately. Add a
mechanical check when it reliably detects a real defect, not a wording preference.
Detailed rule examples belong behind the index, not in the always-loaded manual.

After changing manuals, skills, tool wrappers, hooks, or queue conventions, run
`./run check agent-setup` and `./run gate tooling`. The check verifies discovery,
the root-plus-project 32 KiB instruction budget, skill metadata, KB indexing,
and absence of a project-global Stop hook. Keep command/check logic in `tools/`,
entered through `./run`. Model upgrade evidence and behavioral review cases live
in [.agent/kb/runbooks/agent-maintenance.md](.agent/kb/runbooks/agent-maintenance.md).
