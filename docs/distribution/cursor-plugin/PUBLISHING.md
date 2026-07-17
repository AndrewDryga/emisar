# Publishing the emisar Cursor plugin

This directory is a self-contained public Cursor Marketplace plugin. It contains
only the plugin and marketplace manifests, the remote MCP config, logo, user
documentation, changelog, and Apache-2.0 license. It ships no credentials, rules,
hooks, skills, or agents.

## Release checklist

1. Recheck Cursor's current plugin and remote MCP documentation.
2. Verify `.cursor-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, and
   `.mcp.json` against the current schema.
3. Test a clean local install and OAuth connection to
   `https://emisar.dev/api/mcp/rpc` in a current Cursor build.
4. Exercise one allowed action, one approval-required action, and one policy
   denial against a disposable account with no access to real infrastructure.
5. Confirm every run is attributed and present in the audit log, then destroy
   the disposable account and runner.
6. Bump the manifest version and `CHANGELOG.md`, create a signed tag, and submit
   the public plugin repository through Cursor's publisher portal.
7. After approval, verify a clean Marketplace install and OAuth flow.

Never place reviewer credentials, OAuth tokens, screenshots of private account
data, or submission correspondence in this public directory. Store operational
evidence in the private maintainer system.
