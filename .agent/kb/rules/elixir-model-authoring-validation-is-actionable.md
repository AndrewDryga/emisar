# elixir: model authoring validation is actionable and atomic

**Rule.** A model-facing mutation that accepts a composite, versioned document
returns the owning domain validator's ordered issue report before it reserves an
operation or writes anything. Keep the complete contract in the published tool
schema for authoring guidance. At runtime, defer that owned subtree past any
generic adapter validator that would remove array indexes, collapse paths, or
truncate the domain report.

The response is bounded and machine-repairable: include the total issue count,
exact JSON Pointer paths, stable codes and messages, the ordered visible issue
list, and a boolean saying whether the list was truncated. Never echo submitted
values. Authorization still runs before validation so the response cannot become
an unauthenticated or cross-account schema oracle.

Good: `create_runbook_draft` authorizes, validates DefinitionV1 through
`Emisar.Runbooks.Definition`, and only then derives or reserves its operation ID.
Twenty-one independent errors return all twenty-one paths; a larger report
returns the fixed prefix plus its total count and truncation state.

Bad: let a controller-wide JSON Schema adapter return the first eight normalized
paths; create an idempotency row before definition validation; save an invalid
draft for later inspection; or include invalid argument values in errors or logs.

**Sweep target.** Search MCP write tools for versioned definitions, policies,
workflows, manifests, or other nested authoring documents. Trace validation from
the transport boundary through authorization and the owning context, and verify
that invalid documents leave operation, domain, and audit tables unchanged.

**How it is enforced.** Context tests pin validation before operation reservation.
MCP contract tests pin exact indexed issues, bounded truncation, and absence of
runbook, operation, and audit writes. The published result schema pins the error
shape and maximum visible issue count.
