# emisar — Cursor plugin

Connect Cursor's agent to [**emisar**](https://emisar.dev): one governed MCP
endpoint for real infrastructure actions — gated by policy, approved by a human,
and written to a tamper-evident audit log.

Instead of handing an agent raw SSH, you point it at a single MCP endpoint that
exposes an **approved catalog** of actions. Every call is checked against your
policy (read-only actions run immediately; risky ones pause for a human to
approve; anything outside the catalog is denied by default), attributed to the
accountable operator, and audited. The tool list is per-account and reflects
exactly what your policy and runner scope allow — nothing more.

## What this plugin does

It registers the hosted emisar MCP server (`https://emisar.dev/api/mcp/rpc`) with
Cursor over **OAuth** — no API key to paste, nothing to install locally. On first
use, Cursor sends you through a one-time emisar sign-in and consent screen; after
that, the agent can call the actions your policy already permits.

This plugin is **only** an integration config. It adds no rules, skills, agents,
hooks, or subagents, and it ships **no** credentials. All behavior — the tool
catalog, policy, approvals, and audit — lives in your emisar account.

## Requirements

- An [emisar](https://emisar.dev) account and at least one connected runner.
  See [Connect an LLM](https://emisar.dev/docs/connect-an-llm).
- A recent Cursor build with remote (streamable-http) MCP + OAuth support.

## Install

**From the Cursor Marketplace:** search for **emisar** and click Install, then run
any tool once to trigger the OAuth sign-in.

**Manually:** copy `mcp.json` into your project (or Cursor's global MCP config).
It declares one remote server:

```json
{
  "mcpServers": {
    "emisar": {
      "url": "https://emisar.dev/api/mcp/rpc"
    }
  }
}
```

Because the entry is a bare remote `url`, Cursor uses OAuth (Dynamic Client
Registration) automatically — there is no client id, secret, or bearer token to
configure.

## What the agent can — and can't — do

- **Can:** run the infrastructure actions your policy already permits, attributed
  to you; read the audit trail if your key is granted it.
- **Waits:** risky actions return `pending_approval` and stop until a human
  approves them in the emisar dashboard.
- **Can't:** exceed your policy, reach runners outside your scope, or invoke
  anything that isn't in your approved catalog (default-deny).

Every action call carries a `reason` string that lands on the run and is shown to
approvers and in the audit log.

## Links

- Product & docs: <https://emisar.dev> · [Connect an LLM](https://emisar.dev/docs/connect-an-llm) · [MCP reference](https://emisar.dev/docs/mcp-reference)
- Security model: <https://emisar.dev/docs/security-model> · <https://emisar.dev/security>
- Privacy: <https://emisar.dev/privacy> · Trust: <https://emisar.dev/trust> · Terms: <https://emisar.dev/terms>
- Support: <mailto:support@emisar.dev> · Security: <mailto:security@emisar.dev>

## License

Apache License 2.0 — see [LICENSE](LICENSE). Copyright © 2026 Andrii Dryga.
The emisar name and logo are trademarks of their owner; this license grants no
trademark rights.
