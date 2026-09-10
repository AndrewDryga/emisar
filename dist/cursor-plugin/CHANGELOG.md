# Changelog

All notable changes to the emisar Cursor plugin are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the plugin
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-09-10

### Changed

- `install-emisar` now requires the signed release checksums and verifies them
  before installing or upgrading a runner, and names the runner's group, id,
  and labels the way the console does.
- All three skills call `list_packs` with the argument it accepts.
- `install-emisar` follows the v0.48.0 console flows for account setup and
  runner enrollment.
- README and skill text re-synced with the public `skills/` copies.

## [0.1.0] — 2026-08-05

### Added

- Initial plugin: registers the hosted Emisar MCP server
  (`https://emisar.dev/api/mcp/rpc`) with Cursor over OAuth (Dynamic Client
  Registration — no API key required). The server is declared in `mcp.json`.
- Marketplace manifest (`.cursor-plugin/marketplace.json`) so Cursor installs the
  plugin from its Plugins panel — the Marketplace or **+ Add → From Local Repo**.
- Customer skills for installing and certifying a runner, authoring a custom
  action pack, and responding to production incidents through Emisar.
- README, license (Apache-2.0), and listing icon.

No rules, agents, hooks, subagents, credentials, or executable code are bundled.
