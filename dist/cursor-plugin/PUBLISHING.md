# Publishing the emisar Cursor plugin

This directory is a self-contained public Cursor Marketplace plugin. It contains
the plugin and marketplace manifests, remote MCP config, three portable customer
skills, logo, user documentation, changelog, and Apache-2.0 license. It ships no
credentials, rules, hooks, agents, subagents, or executable code.

## Release checklist

1. Recheck Cursor's current plugin and remote MCP documentation and publisher
   terms.
2. Verify `.cursor-plugin/marketplace.json`, `.cursor-plugin/plugin.json`,
   `mcp.json`, and every `skills/*/SKILL.md` against the current Cursor schemas
   and plugin quality checks.
3. Copy the package to `~/.cursor/plugins/local/emisar`, restart Cursor, and test
   a clean local install plus OAuth connection to
   `https://emisar.dev/api/mcp/rpc` in a current Cursor build.
4. Confirm the three bundled skills appear. Exercise one allowed action, one
   approval-required action, and one policy denial against a disposable account
   with no access to real infrastructure.
5. Confirm every run is attributed and present in the audit log, then destroy
   the disposable account and runner.
6. Bump the manifest version and `CHANGELOG.md` for later releases. For the
   initial release, create a signed `v0.1.0` tag and submit the public plugin
   repository through Cursor's publisher portal.
7. After approval, verify a clean Marketplace install and OAuth flow.

Never place reviewer credentials, OAuth tokens, screenshots of private account
data, or submission correspondence in this public directory. Store operational
evidence in the private maintainer system.
