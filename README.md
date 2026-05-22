# emisar

**Local enforcement runner for AI-safe infrastructure actions.**

emisar is a single Go binary that runs on a VM (or in a container) and
lets a cloud control plane orchestrate a curated, declared, fully
journaled set of operational actions on that host — without giving the
LLM raw shell or SSH access, and without opening any inbound port.

Status: **v0.2, local-runner only.** The cloud control plane (policy
authoring, approval workflow, audit storage, runbook orchestration) is
out of scope for this repository, but the wire protocol and transport
interfaces are defined. See [`docs/cloud-boundary.md`](docs/cloud-boundary.md)
and [`docs/wire-protocol.md`](docs/wire-protocol.md).

## What it does

- Loads **action packs** baked into the VM image at build time.
- Dials **out** to the cloud over a TLS websocket — no inbound listener.
- Advertises every action it can run (full schemas) to the cloud.
- For each `run_action` message from cloud:
  1. Re-validates arguments against the action's declared schema.
  2. Clamps cloud-supplied opts to the action's `*_min`/`*_max` bounds.
  3. Executes via `os/exec` with **argv arrays, never shell strings**.
  4. Streams line-buffered, redacted output back over the websocket.
  5. Writes one JSONL event per attempt to the local security log.
- Refuses anything not declared or not validated.

## What it deliberately is NOT

- Not a sandbox or process isolator.
- Not a cloud service. No listener, no UI, no audit search here.
- Not the audit system of record — cloud is. JSONL is for on-host
  forensics.
- Not a policy engine — the control plane decides what should run,
  the runner decides whether the *inputs* match the declared schema.

See [`docs/security-model.md`](docs/security-model.md).

## Install (production)

For a supervised daemon install on Linux (systemd) or macOS (launchd):

```sh
curl -sSL https://raw.githubusercontent.com/andrewdryga/emisar/main/install.sh | sudo bash
```

This downloads the latest tagged release, verifies SHA256, creates a
dedicated service user (Linux), installs `/usr/local/bin/emisar`, drops
a config skeleton at `/etc/emisar/`, and installs the systemd unit or
launchd plist with `Restart=on-failure` supervision and `StartLimitBurst`
caps.

After install, edit `/etc/emisar/config.yaml` and `/etc/emisar/runner.env`,
then `sudo systemctl start emisar`. See
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
| [docs/cloud-boundary.md](docs/cloud-boundary.md)    | What the cloud will own; what the runner will own.    |
| [docs/wire-protocol.md](docs/wire-protocol.md)      | JSON message types, connection lifecycle, opts.      |

## Repository layout

Monorepo with one folder per deployable component (mirrors firezone's
language-rooted layout). Each Go folder is its own module; the Elixir
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
docker/                          docker-compose + Dockerfile for runner dev container
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
contact `licensing@dryga.com`.
