# Public customer skills live under `skills/`

## Rule

A skill distributed to Emisar customers lives at `skills/<skill-name>/SKILL.md`
with portable `name` and `description` frontmatter. It must operate through
public product interfaces and must not depend on an Emisar repository checkout,
`AGENTS.md`, `.agent/`, `.claude/skills/`, `.codex/skills/`, or another internal
contributor skill.

Contributor engineering skills remain under `.claude/skills/` and may use the
repository's internal manuals and tooling. Do not place a customer workflow
there, even when maintainers also use it.

## Why

Customers install skills into their own agent environment. A skill that assumes
the Emisar monorepo or its contributor setup is present is unusable during
onboarding and exposes internal process as a false product dependency.

## Good

- Publish `skills/install-emisar/SKILL.md`.
- Install it directly from a release tag or commit SHA.
- Discover commands from public installers, portal snippets, installed CLI
  help, and public documentation.

## Bad

- Publish a customer workflow only under `.claude/skills/`.
- Tell a customer to clone or fork Emisar before installing the product.
- Require internal hats, task queues, manuals, or source files to operate a
  public skill.

## Enforcement

`bash .agent/scripts/audit-llm-setup.sh` validates the public skill tree,
portable frontmatter, and separation from contributor skill directories.
Review public skill instructions for public-interface-only dependencies.
