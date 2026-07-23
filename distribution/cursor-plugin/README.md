# emisar for Cursor

Let Cursor investigate and act on infrastructure through emisar's declared
action catalog, without giving the agent an SSH key or an open-ended shell.
Policy decides what runs, what waits for a person, and what is denied; the
runner checks the exact pack and arguments again on the host.

This package registers the hosted emisar MCP endpoint with Cursor. It contains
no credential, code hook, rule, skill, subagent, or second backend. Tools,
runner scope, policy, approval, and audit remain in the operator's emisar
account.

**Publication status:** this directory is the ready-to-submit plugin scaffold.
The Marketplace listing is not public yet. Use the direct MCP configuration
below today; the plugin will register the same endpoint after publication.

## Connect now

You need an [emisar account](https://emisar.dev/sign_up) with at least one
connected runner and a current Cursor build with remote Streamable HTTP MCP and
OAuth support.

Add this to the project's `.cursor/mcp.json`, or to `~/.cursor/mcp.json` to make
emisar available in every workspace:

```json
{
  "mcpServers": {
    "emisar": {
      "url": "https://emisar.dev/api/mcp/rpc"
    }
  }
}
```

Restart Cursor, open its MCP settings, and authenticate the `emisar` server.
Cursor follows the endpoint's OAuth discovery flow; there is no client ID,
secret, or API key to paste into the file.

Confirm the connection by asking Cursor to list the infrastructure in scope.
Then run a low-risk action such as `linux.uptime`. You are done when the result
returns to Cursor and the run appears in the emisar audit trail.

The complete setup and troubleshooting guide is at
[emisar.dev/docs/connect-an-llm](https://emisar.dev/docs/connect-an-llm).

## What Cursor receives

emisar exposes a fixed MCP tool surface that lets Cursor:

- discover connected runners, installed packs, and declared actions in scope;
- read the exact schema, risk, limits, and side effects of an action;
- dispatch an action with typed arguments and a required reason;
- wait for or recover the result of a run;
- read permitted audit activity.

Packs add infrastructure capabilities behind those tools. Installing a pack
does not require another Cursor integration.

Every call is attributed to the signed-in emisar member. Their runner scope
limits which hosts are visible. Account policy decides whether the action runs,
waits for approval, or is denied. Cursor cannot use this connection to bypass
pack trust, policy, approval, runner-local admission, or runner-side argument
validation.

## Security boundary

The plugin stores no static credential. OAuth tokens are issued through emisar
and can be revoked from **LLM agents** in the dashboard or from Cursor's MCP
settings.

The runner is outbound-only and executes only actions declared in locally
installed, content-addressed packs. It redacts output before transmission and
writes every attempt to a hash-chained local journal while the control plane
keeps the fleet audit trail.

emisar is not a sandbox. An action that policy permits runs with the OS
permissions granted to the runner service user. Review the exact guarantees and
limits at [emisar.dev/docs/security-model](https://emisar.dev/docs/security-model).

## Plugin maintainers

Before Marketplace submission, lift this directory to the root of its dedicated
public repository, then follow [`PUBLISHING.md`](PUBLISHING.md). Validate a clean
install and the OAuth success, approval, denial, and audit-attribution paths in
a current Cursor build before publishing.

The package must stay credential-free and minimal. If the product needs richer
agent guidance later, add it only with live evidence that it improves safe tool
use; do not duplicate server-side policy or tool semantics in Cursor files.

## Links

- [emisar](https://emisar.dev) and [quickstart](https://emisar.dev/docs/quickstart)
- [Connect an LLM](https://emisar.dev/docs/connect-an-llm)
- [MCP reference](https://emisar.dev/docs/mcp-reference)
- [Trust center](https://emisar.dev/trust), [privacy](https://emisar.dev/privacy), and [terms](https://emisar.dev/terms)
- Support: <support@emisar.dev>; security: <security@emisar.dev>

## License

Apache License 2.0. See [LICENSE](LICENSE). Copyright 2026 Andrii Dryga.
The emisar name and logo are trademarks of their owner; this license grants no
trademark rights.
