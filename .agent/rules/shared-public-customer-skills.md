# Public customer skills stay portable and contract-accurate

## Rule

A skill distributed to Emisar customers lives at `skills/<skill-name>/SKILL.md`
with portable `name` and `description` frontmatter. It must operate through
public product interfaces and must not depend on an Emisar repository checkout,
`AGENTS.md`, `.agent/`, `.claude/skills/`, `.codex/skills/`, or another internal
contributor skill.

Contributor engineering skills remain under `.claude/skills/` and may use the
repository's internal manuals and tooling. Do not place a customer workflow
there, even when maintainers also use it.

When a public skill names MCP tools or mechanics, use the canonical names and
values from `docs/mcp-api-schemas.json` and preserve the live server's
continuation contract. Follow a returned `next` call verbatim before composing
another call; compose a new call only for a distinct question the continuation
does not answer. Do not hand-maintain renamed tool names, enum labels, or
derived identifiers in customer instructions.

## Why

Customers install skills into their own agent environment. A skill that assumes
the Emisar monorepo or its contributor setup is present is unusable during
onboarding and exposes internal process as a false product dependency.

## Good

- Publish `skills/install-emisar/SKILL.md`.
- Install it directly from a release tag or commit SHA.
- Discover commands from public installers, portal snippets, installed CLI
  help, and public documentation.
- Cite `list_packs` with its real `availability: "all"` input and follow a
  returned candidate's `next` call to `get_action`.

## Bad

- Publish a customer workflow only under `.claude/skills/`.
- Tell a customer to clone or fork Emisar before installing the product.
- Require internal hats, task queues, manuals, or source files to operate a
  public skill.
- Describe a nonexistent MCP mode such as "diagnostic availability" or rebuild
  a follow-up call when the server already returned its exact continuation.

## Enforcement

`bash .agent/scripts/audit-llm-setup.sh` validates the public skill tree,
portable frontmatter, separation from contributor skill directories, and every
backticked MCP tool-shaped name against `docs/mcp-api-schemas.json`. Review
public skill instructions against the live schemas and initialize instructions
for fields, enum values, and continuation semantics that a name check cannot
prove.
