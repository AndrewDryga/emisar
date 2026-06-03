---
name: boundaries
description: Audit context boundaries and coupling in portal/apps/emisar via mix xref + greps — find the web/MCP layer reaching past contexts, one context reaching into another's Query/Schema/Changeset, and dependency cycles. Use before splitting a context, after adding cross-context calls, or to check architecture health.
effort: medium
argument-hint: "[context name to focus on]"
allowed-tools: Read, Grep, Glob, Bash
---

# Context boundary audit

The architecture has one rule that everything else hangs off: **the context module
is the only public surface.** This skill checks that the rule holds.

## What's allowed to call what

| Layer | May call | May NOT call |
|-------|----------|--------------|
| LiveView / controller / channel / MCP | context public functions, `CoreComponents`, PubSub | `Repo`, a schema's `Query`/`Changeset`/`Schema` directly |
| Context (`lib/emisar/<ctx>.ex`) | its own schemas/Query/Changeset, `Repo`, **other contexts' public API** | another context's `Query`/`Changeset`/`Schema` internals; web-layer modules |
| Query / Changeset / Schema | (pure building blocks) | `Repo` (Query/Changeset), each other |

## Checks

**1. Web/MCP bypassing contexts** (the most common drift):
```sh
cd portal
rg -n '\bRepo\.' apps/emisar_web/lib            # should be ~none — go through a context
rg -n 'Emisar\.\w+\.(Query|Changeset)\b' apps/emisar_web/lib   # web reaching into internals
```

**2. One context reaching into another's internals:**
```sh
# in lib/emisar/<ctx>.ex, references to ANOTHER context's Query/Changeset/Schema
rg -n 'Emisar\.\w+\.(Query|Changeset)\b' apps/emisar/lib/emisar/*.ex
```
A context should call `OtherContext.fetch_thing(id, subject)`, not
`OtherContext.Thing.Query.by_id/1`.

**3. Coupling + cycles** (mix xref — confirm the flags with `mix help xref`):
```sh
cd portal
mix xref graph --format stats                       # fan-in / fan-out per module
mix xref graph --format cycles --label compile      # compile-time cycles (should be none)
mix xref callers Emisar.<Ctx>.<fun>                 # who depends on a function before you change it
```

## Output

Report each violation as `file:line → which boundary → the fix` (almost always:
"add a public function to context X and call that"). List the coupling hotspots
(a context with high fan-out may be doing too much) and any cycle. Don't move
modules around without running xref first — refactoring boundaries blind creates new
violations. Fixes that add a context function: hand to `/context-fn`.
