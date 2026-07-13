---
name: workflow-spec
description: Design an opinionated, boring-by-default implementation plan for an emisar change before writing code. Use when a change spans more than one file, context, or project; when the approach is not obvious; or when the user asks to plan/design/think through a feature. Maps the slice to the touched project AGENTS.md gate and produces small verifiable steps to approve before /workflow-work.
effort: medium
argument-hint: "<what you want to build>"
allowed-tools: Read, Grep, Glob, Bash
---

# /workflow-spec — plan a change (the boring, shippable way)

Produce a plan the user can approve, then hand to `/workflow-work`. Optimize for the
smallest correct slice, not the grandest design. Read root `AGENTS.md`, then the
`AGENTS.md` for every touched project **before** planning — plan against the real
code, not a guess.

## 1. Wear the PM hat first (don't skip)

Before *how*, settle *whether* and *what*:
- What's the actual job-to-be-done, and who for? (emisar's users are operators
  running infra actions through approvals/policies, and LLMs via MCP.)
- What's the **smallest slice** that delivers it? Cut everything else into "later".
- Does this already exist as a function on an existing context? If so, it's a
  `/elixir-context-fn`, not a project.

If the request is vague or oversized, say so and propose the thin slice. Pull the
`/product-manager` hat for a real prioritization call.

## 2. Map the work onto the touched project

Walk the relevant layers and name what changes in each (skip what does not apply):
- **portal/** — migration/schema, query, changeset, authorizer, context API, web/MCP,
  tests. Name the happy / denial / cross-account cases per public function.
- **runner/ or mcp/** — package touched, trust boundary, validation/exec/transport path,
  table-driven tests, race/vet gate, and whether the Debian container is needed.
- **packs/** — pack/action manifest contract, arg bounds, risk, version/hash impact,
  validation command, and redis/cassandra golden update if touched.
- **infra/** — Terraform resource, SOC 2/security invariant, docs/compliance update, and
  fmt/init/validate/tflint gate.
- **agent tooling/docs** — canonical source of truth, duplicate/stale text removed,
  adoption check added or updated.

## 3. Choose boring on purpose

For each non-obvious decision, write the chosen approach and a one-line *why it's
the dull option*. If you reach for something clever (a new GenServer, a macro, a
dependency), justify why boring can't do it — or drop it. No new abstraction that
serves one caller.

## 4. Flag the hats to consult

Name which lenses this change leans on, so `/workflow-work` and `/review-ship` know:
- touches auth / runner trust / MCP / untrusted input → `/security-engineer` (likely mandatory)
- new operator screen/flow → `/design-ux` + `/design-frontend`
- marketing/docs/positioning → `/content-seo`

## 5. Output

```
## Plan: <title>
Slice: <one sentence — what ships, what's deferred>

Steps (each independently compilable + testable):
1. <project/layer> — …
2. <project/layer> — …
3. <tests/gate> — …

Tests: <the denial + cross-account cases, by name, or the touched project's equivalent gate>
Hats: <which, and the open question for each>
Risks / unknowns: <bullets, or "none">
```

Keep it to what's needed — a 3-line plan for a 3-line change. **Present it and
stop for approval.** Don't write code in this skill.
