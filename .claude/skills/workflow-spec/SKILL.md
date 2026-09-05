---
name: workflow-spec
description: Plan an Emisar change when the approach needs design, several layers interact, or the user requests a plan. Define the complete outcome, decisions, and verification before implementation.
effort: medium
argument-hint: "<what you want to build>"
allowed-tools: Read, Grep, Glob, Bash
---

# Plan the requested change

Read the root and touched project AGENTS.md, then the relevant implementation and
references. Preserve the user's requirements, accepted decisions, and authority.
A multi-file change alone does not require a separate planning conversation.

Define the complete outcome, the smallest implementation that delivers it, the
affected layers, and meaningful verification. Use existing contexts, components,
and tools. State assumptions and explain consequential tradeoffs briefly.
Recommend scope changes when needed; do not silently defer requested behavior.

For Portal context changes, name the happy, denial, and cross-account paths.
For runner/MCP/packs, identify affected execution contracts and abuse cases.
For infrastructure, distinguish source validation, plan, apply, and live proof.
For agent instructions, check discovery, conflicting rules, and actual behavior.
Name the touched projects' canonical final gates and other required checks.

Consult specialist skills when the change needs their judgment. Keep the plan
proportional: outcome, implementation steps, verification, and unresolved decisions.

If the user requested only a plan or assessment, deliver that and stop. If they
authorized implementation, continue with workflow-work after planning; no second
approval is needed for routine steps. Ask only when a missing decision or authority
materially changes the result, after completing independent authorized work.
