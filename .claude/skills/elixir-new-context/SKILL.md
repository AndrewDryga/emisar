---
name: elixir-new-context
description: Build a new Emisar domain context with schema, query, changeset, authorizer, migration, and tests wired into the permission union.
effort: high
argument-hint: "<Context> <Schema> e.g. Widgets Widget"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Build a context

Read portal/AGENTS.md and sections 1–5, 7, and 8 of
portal/.agent/kb/rules/elixir-layered-contexts.md before scaffolding.
Those fictional Widgets templates own the module shapes. Inspect the surrounding
implementation for the actual domain; do not duplicate the templates in this skill.

Confirm the concept belongs in a new context rather than an existing one. Preserve
the user's requested behavior and continue under their implementation authority.

Create the migration, schema, query, changeset, authorizer, context API, and tests.
Honor production-applied migration immutability, UUID keys, soft-delete filtering,
DB constraints, composable queries, pure changesets, and fail-closed row scope.
Register the authorizer in lib/emisar/auth/permissions.ex so its permissions reach
the Subject. Verify existing roles in Emisar.Auth.Role and neighboring authorizers.

Public functions state permission and tagged-return contracts. Required Subject
arguments come last; callers authorize and scope through the context. Read the
reference's internal/self-service exceptions before choosing a different shape.

Use the real domain-namespaced Fixtures modules in test/support, with separate
happy, denial, and cross-account cases for the API behavior. Match existing test
order and arrange only the state each case requires.

Use focused tests while implementing. The lead runs the final ./run gate portal
and obtains a trust-boundary review before committing. Complete all requested
layers; a context-only request does not itself authorize adding a LiveView.
