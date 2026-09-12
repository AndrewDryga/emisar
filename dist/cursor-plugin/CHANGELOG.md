# Changelog

All notable changes to the emisar Cursor plugin are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the plugin
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-09-10

### Changed

- `install-emisar` verifies the signed release checksums before installing or
  upgrading a runner when GitHub CLI is present, and otherwise asks before
  continuing on the release checksum alone — warning and continuing under
  `--yes`. It also names the runner's group, id, and labels the way the console
  does.
- `install-emisar` requires HTTPS for installer downloads, and permits plain
  HTTP only for loopback and literal private addresses that pass a `python3`
  origin check.
- `install-emisar` downloads the installer with the conventional
  `curl -fsSL`.
- `author-pack` builds `packctl` from the signed release tag the runners were
  installed from, instead of `go install …@latest`.
- All three skills call `list_packs` with the argument it accepts.
- `install-emisar` diagnoses a runner that installs but never joins the fleet
  from the host log instead of guessing, and names what a `401`, `409`, or
  `402` registration failure means and the operator's remedy for each.
- `author-pack` requires a nonempty `allowed_prefixes` or `allowed_paths` to
  contain a path argument, and describes `denied_prefixes`/`denied_paths` as
  optional extra exclusions rather than containment — a deny-only rule
  resolves the value canonically but still admits every path it did not name.
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
