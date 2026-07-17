# Changelog

All notable changes to the emisar Cursor plugin are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the plugin
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-07-10

### Added

- Initial plugin: registers the hosted emisar MCP server
  (`https://emisar.dev/api/mcp/rpc`) with Cursor over OAuth (Dynamic Client
  Registration — no API key required). The server is declared in `.mcp.json`.
- Marketplace manifest (`.cursor-plugin/marketplace.json`) so Cursor installs the
  plugin from its Plugins panel — the Marketplace or **+ Add → From Local Repo**.
- README, license (Apache-2.0), and listing icon.

No rules, skills, agents, hooks, or subagents are bundled — the plugin is an MCP
integration config only.
