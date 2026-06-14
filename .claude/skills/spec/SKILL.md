---
name: spec
description: Design an opinionated, boring-by-default implementation plan for a portal/ change before writing code. Use when a change spans more than one file or context, when the approach isn't obvious, or when the user asks to plan/design/think through a feature. Produces a small-step, verifiable plan to approve before /work.
effort: medium
argument-hint: "<what you want to build>"
allowed-tools: Read, Grep, Glob, Bash
---

# /spec — plan a change (the boring, shippable way)

Produce a plan the user can approve, then hand to `/work`. Optimize for the
smallest correct slice, not the grandest design. Read `portal/AGENTS.md` (laws +
prime directive) and the contexts you'll touch **before** planning — plan against
the real code, not a guess.

## 1. Wear the PM hat first (don't skip)

Before *how*, settle *whether* and *what*:
- What's the actual job-to-be-done, and who for? (emisar's users are operators
  running infra actions through approvals/policies, and LLMs via MCP.)
- What's the **smallest slice** that delivers it? Cut everything else into "later".
- Does this already exist as a function on an existing context? If so, it's a
  `/context-fn`, not a project.

If the request is vague or oversized, say so and propose the thin slice. Pull the
`/product-manager` hat for a real prioritization call.

## 2. Map the work onto the layered-context shape

Walk the layers and name what changes in each (skip the ones that don't):
- **Migration / schema** — new table or columns? (IL-12 money, soft-delete, indexes.)
- **Query** — what new predicates/ordering/filters? (They go in the Query module.)
- **Changeset** — which new state transitions?
- **Authorizer** — new permission, or reuse `view/manage`? New role grants?
- **Context** — the public functions (name them; each takes `%Subject{}`, returns tagged tuples).
- **Web / MCP** — which LiveView/controller/MCP action; what events; what's streamed.
- **Tests** — name the happy / denial / cross-account cases per function.

## 3. Choose boring on purpose

For each non-obvious decision, write the chosen approach and a one-line *why it's
the dull option*. If you reach for something clever (a new GenServer, a macro, a
dependency), justify why boring can't do it — or drop it. No new abstraction that
serves one caller.

## 4. Flag the hats to consult

Name which lenses this change leans on, so `/work` and `/ship-review` know:
- touches auth / runner trust / MCP / untrusted input → `/security-engineer` (likely mandatory)
- new operator screen/flow → `/ux-designer` + `/frontend`
- marketing/docs/positioning → `/seo-marketing`

## 5. Output

```
## Plan: <title>
Slice: <one sentence — what ships, what's deferred>

Steps (each independently compilable + testable):
1. <migration/schema> — …
2. <query + changeset> — …
3. <context fns + tests> — …
4. <web/mcp> — …

Tests: <the denial + cross-account cases, by name>
Hats: <which, and the open question for each>
Risks / unknowns: <bullets, or "none">
```

Keep it to what's needed — a 3-line plan for a 3-line change. **Present it and
stop for approval.** Don't write code in this skill.
