# Public claims follow their owned contracts

## Rule

A public count, plan entitlement, integrity property, or security claim comes
from the implementation that owns it. When two layers provide related
controls, name the layer and state only what that layer proves.

- MCP tool counts come from the compiled MCP schema registry.
- Required MCP release clients come from the certification workflow's required
  lanes; evaluator support alone does not make a provider a release gate.
- Plan features follow the billing entitlement, not nearby pricing prose.
- Portal audit records and the runner's host-local journal are separate
  evidence layers. Hash-chain verification proves continuity of the retained
  journal; it does not prove that host root preserved every original record.

## Why

These claims shape purchase and security decisions. A stale number makes the
product look internally inconsistent. A plan mismatch promises a feature the
account cannot use. Collapsing two audit layers turns a bounded integrity check
into a claim the product cannot prove.

## Good

```text
Portal audit: searchable off-host record of actions and policy decisions.
Runner journal: hash-chained records retained on each host.
```

```elixir
@mcp_tool_count length(EmisarWeb.MCP.SchemaRegistry.tool_names())
```

## Bad

```text
The audit command catches any edited or missing line.
```

```text
84 MCP tools
```

when the compiled MCP registry exposes twelve.

## Enforcement

Marketing tests pin the pricing row to the billing contract, derive the home
page count from the MCP schema registry, and require the Trust Center to name
both audit layers. When one of these contracts changes, sweep public templates,
structured data, docs, runbooks, and policy pages for the old count,
entitlement, required certification lane, or unqualified claim.
