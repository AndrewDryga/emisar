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
- Outbound runner connectivity means the runner establishes the TLS WebSocket
  and exposes no inbound listener. Commands still return through that established
  connection; never turn connection direction into a claim that no command
  reaches the host.
- Signed dispatch attributes a frame to the customer-authorized MCP bridge and
  its locally held signing key. A person provisions the trust chain but does not
  personally sign every dispatch frame.
- Runner output claims name runner-side pattern redaction before egress and do
  not promise detection of novel secret shapes. Run history retains bounded
  redacted output; Portal audit events retain decision/execution metadata and
  redaction counts; the host journal retains bounded previews plus full-stream
  digests. Never collapse those stores into one evidence layer.
- Supply-chain levels follow the actual builder isolation. Direct GitHub
  artifact attestations are SLSA Build Level 2; claim Level 3 only after the
  release uses a hardened reusable builder that meets that level's contract.

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
entitlement, required certification lane, unqualified connectivity or signing
claim, raw-output wording, or unsupported supply-chain level.
