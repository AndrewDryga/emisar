# Rule: repository knowledge lives in the KB

The website owns customer and operator documentation. Repository knowledge that
does not belong in code lives under `.agent/kb/`:

- descriptive current-system facts are cards directly under `kb/`;
- versioned interface and security contracts live under `kb/specs/`;
- ordered maintainer procedures live under `kb/runbooks/`;
- constraints changes must obey live under `kb/rules/`;
- non-customer-facing working material lives under ignored `kb/internal/`.

Machine-readable contracts stay beside the implementation that owns and
consumes them, with the human specification linking to that source. Published
manifests, licenses, assets, and package README files stay beside the artifact
in an explicitly tracked subtree under `dist/`. Generated `dist/` siblings
remain ignored.

Do not create a top-level `docs/` directory. It becomes a second, stale
documentation site beside the actual website and makes agents guess which copy
is authoritative.

## Why

One routing index lets agents load only the knowledge relevant to the task.
Keeping product documentation on the website prevents repository prose from
quietly becoming a second customer surface. Keeping executable contracts and
distribution inputs with their owners avoids build-context exceptions and
false ownership boundaries.

## Good

```text
.agent/kb/architecture.md
.agent/kb/specs/wire-protocol.md
.agent/kb/runbooks/release.md
portal/apps/emisar_web/priv/mcp/api-schemas.json
dist/cursor-plugin/README.md
```

## Bad

```text
docs/architecture.md
docs/mcp-api-schemas.json
docs/distribution/cursor-plugin/
```

Those paths mix agent knowledge, executable application inputs, and published
artifacts under an unused repository documentation surface.

## Enforcement

`./run check agent-setup` rejects top-level `docs/` and `distribution/`
directories, validates descriptive cards separately from specs and runbooks,
reads public-skill MCP tool names from the portal-owned schema, and exercises
Git's ignore matcher to prove `dist/cursor-plugin/` is trackable while generated
`dist/` siblings stay ignored.

Sweep new Markdown, JSON specifications, release procedures, and distribution
assets for a `docs/` owner before adding them. A new tracked `dist/` subtree
must also receive an exact `.gitignore` exception; never unignore generated
output wholesale.
