# emisar

**Approved infrastructure actions for AI tools, enforced on-host.**

emisar is a control plane, outbound-only runner, and MCP bridge for
letting AI tools request a finite, declared set of operational actions
without receiving raw shell or SSH access.

Status: **active private beta.** This monorepo contains the complete
runner, Phoenix control plane, public website, and MCP stdio bridge.
The hosted control plane is the current supported product boundary;
self-hosted and air-gapped deployments are not generally available.

## What it does

- Loads versioned, content-addressed **action packs** on each runner.
- Dials **out** to the control plane over a TLS websocket — no inbound listener.
- Blocks dispatch when a runner advertises new, custom, or changed pack contents
  until an admin trusts the hash.
- Connects remote MCP clients through OAuth and local clients through the
  `emisar-mcp` stdio bridge.
- Applies per-user runner scopes, risk-tier policy, action overrides,
  human approvals, and revocable standing grants.
- For each `run_action` message from cloud:
  1. Re-validates arguments against the action's declared schema.
  2. Recomputes and verifies the trusted pack hash.
  3. Clamps cloud-supplied opts to the action's `*_min`/`*_max` bounds.
  4. Executes via `os/exec` with **argv arrays, never shell strings**.
  5. Streams line-buffered, redacted output back over the websocket.
  6. Writes one hash-chained JSONL event per attempt to the local security log.
- Mirrors run state into a searchable audit log with a read-only SIEM export.

## What it deliberately is NOT

- Not a sandbox or process isolator.
- Not an arbitrary remote shell or generic `execute(command)` tool.
- Not a replacement for OS-level least privilege, process isolation, or
  customer change-management controls.
- Not OSI-approved open source. The repository is source-available under
  [`LICENSE.md`](LICENSE.md).

See [`docs/security-model.md`](docs/security-model.md).

## Install (production)

Create a runner from the portal to receive a scoped bootstrap key and
generated install command. The underlying supervised installer for Linux
(systemd) and macOS (launchd) is:

```sh
curl -sSL https://raw.githubusercontent.com/andrewdryga/emisar/main/install.sh | sudo bash
```

This downloads the latest tagged release, verifies SHA256, creates a
dedicated service user (Linux), installs `/usr/local/bin/emisar`, drops
a config skeleton at `/etc/emisar/`, and installs the systemd unit or
launchd plist with `Restart=on-failure` supervision and `StartLimitBurst`
caps.

After install, edit `/etc/emisar/config.yaml` and `/etc/emisar/runner.env`
if the portal-generated command did not populate them, then start the
service. See
[`docs/install.md`](docs/install.md) for upgrade, uninstall, air-gapped
install, and full operational commands.

## Quick start (dev / local)

Commands run from the repo root. The runner is its own Go module under
`runner/` (see [Repository layout](#repository-layout) below) — `make
build` puts the binary at `bin/emisar`:

```sh
# 1. Build the runner + MCP bridge
make build

# 2. Validate the bundled example packs
./bin/emisar pack validate ./runner/examples/packs/linux-core
./bin/emisar pack validate ./runner/examples/packs/cassandra
./bin/emisar pack validate ./runner/examples/packs/showcase

# 3. See what the runner would advertise to cloud
./bin/emisar --config ./runner/examples/config.yaml state | jq

# 4. Run an action locally for debugging (bypasses cloud)
./bin/emisar --config ./runner/examples/config.yaml \
    action run linux.uptime --reason "smoke test"

# 5. Stream a long-running action's output
./bin/emisar --config ./runner/examples/config.yaml \
    action run linux.journalctl --arg unit=docker --stream

# 6. Inspect the JSONL log
./bin/emisar --config ./runner/examples/config.yaml events tail --lines 20
```

To run in daemon mode (waiting for cloud commands):

```sh
EMISAR_AUTH_KEY=emkey-auth-... \
  ./bin/emisar --config ./runner/examples/config.yaml connect
```

## Documentation

| Doc                                                 | Topic                                                |
| --------------------------------------------------- | ---------------------------------------------------- |
| [docs/architecture.md](docs/architecture.md)        | Package layout, runtime pipeline, boot sequence.     |
| [docs/install.md](docs/install.md)                  | Production install, supervised operation, upgrade.   |
| [docs/security-model.md](docs/security-model.md)    | Threats considered and explicitly not considered.    |
| [docs/action-packs.md](docs/action-packs.md)        | How to write a pack.                                 |
| [docs/cloud-boundary.md](docs/cloud-boundary.md)    | What the control plane and runner each enforce.        |
| [docs/wire-protocol.md](docs/wire-protocol.md)      | JSON message types, connection lifecycle, opts.      |

## Repository layout

Monorepo with one folder per deployable component, in a language-rooted
layout. Each Go folder is its own module; the Elixir
control plane is an umbrella project. `go.work` ties the two Go modules
together for editor + CLI convenience.

```
portal/                          Elixir/Phoenix control plane (umbrella)
  apps/emisar/                     domain contexts: accounts, runs, policies, audit, billing
  apps/emisar_web/                 LiveView dashboard + marketing site + MCP HTTP API
runner/                          Go module — on-host runner binary
  main.go, connect.go, …           CLI (cobra)
  internal/cloud                   wire protocol + outbound websocket client
  internal/engine                  action runtime (validate → clamp → execute → redact → journal)
  internal/packs                   pack loader + in-memory registry
  internal/executor                exec/script process runner (line-buffered streaming)
  internal/validation              arg schema enforcement
  internal/expressions             tiny argv-substitution template engine
  internal/redact                  output redaction
  internal/audit                   hash-chained JSONL event log
  internal/config                  config loader
  pkg/actionspec                   action spec types (YAML schema)
  pkg/packspec                     pack manifest types
  examples/packs/                  example packs (linux-core, cassandra, showcase)
  examples/config.yaml             example runner config
mcp/                             Go module — stdio MCP bridge for Claude Code / Cursor / etc.
docs/                            architecture, security, action-packs, cloud-boundary, wire-protocol
compose.yaml                     Full local stack: Postgres, portal, seeder, and runners
install.sh                       supervised install (systemd / launchd) — run against tarball
Makefile                         dev orchestrator (build, test, lint across modules)
```

## License

This repository is **source-available**, not OSI-approved open source.

The code is available so users can inspect it, evaluate it, run permitted
internal uses, understand how it works, and contribute improvements. It is
not available for cloning the product, operating a competing service,
commercial redistribution, AI training, model fine-tuning, embeddings
corpora, clean-room replication, or building a substitute product.

See:

- [`LICENSE.md`](./LICENSE.md)
- [`AI-USE-POLICY.md`](.github/AI-USE-POLICY.md)
- [`CONTRIBUTING.md`](.github/CONTRIBUTING.md)
- [`CLA.md`](.github/CLA.md)
- [`NOTICE.md`](.github/NOTICE.md)
- [`SECURITY.md`](.github/SECURITY.md)

For commercial licensing, hosted use, AI permissions, or other rights,
contact `licensing@emisar.dev`.
