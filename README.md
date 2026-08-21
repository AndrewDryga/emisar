# emisar

**Leave the agent working. Keep production authority bounded.**

emisar gives MCP-capable agents a catalog of declared infrastructure actions
instead of a shell. Policy decides what runs, what waits for a person, and what
is denied. A small outbound-only runner checks the action again on the host
before it executes anything.

Start with the public pack catalog, let emisar suggest the packs that match a
host, and add your own actions without adding another MCP server to every
client.

## Start with one host

You need an [emisar account](https://emisar.dev/sign_up), a Linux host with
systemd and `sudo`, and outbound HTTPS access to `emisar.dev:443` and
`registry.emisar.dev:443`. The first host serves the control plane, installer,
and release archives; the second serves action packs. You do not need direct
GCS access or an inbound port on the host.

1. In the dashboard, choose **Connect a runner**. Copy the generated command;
   it contains a fresh, single-use enrollment key.
2. Run it on the host:

   ```sh
   curl -fsSL https://emisar.dev/install.sh \
     | sudo EMISAR_ENROLLMENT_KEY=emkey-enroll-... bash
   ```

   The installer verifies the release checksum, creates the service, installs
   host-matched starter packs, and starts the runner.
3. Confirm the runner is online in the dashboard, then dispatch
   `linux.uptime` with a reason. You are done when the output appears and the
   run is present in the audit trail.
4. Open **LLM agents** and connect your client. Remote MCP clients use OAuth;
   local stdio clients can use the `emisar-mcp` bridge and its browser approval
   flow.

The complete walkthrough, including expected output and troubleshooting, is at
[emisar.dev/docs/quickstart](https://emisar.dev/docs/quickstart). An agent can
perform and certify the setup with the public
[`install-emisar` skill](skills/install-emisar/SKILL.md).

## How an action runs

```text
AI client
    |  MCP: discover actions, request one with typed arguments
    v
emisar control plane
    |  authenticate, scope, apply policy, wait for approval when required
    v
outbound-only runner
    |  verify pack hash, validate arguments, enforce local limits
    v
declared host command
       stream redacted output, journal the attempt, update fleet audit
```

The action pack is the contract. It fixes the executable, argv shape, argument
schema, risk, timeout, output limits, redaction, and side-effect description.
The model selects from that contract; it does not invent a command line for the
runner to execute.

Adding a pack adds capabilities behind the same MCP surface. Operators do not
need to deploy another tool server or reconfigure every agent when the catalog
changes.

## What holds the boundary

- **No inbound runner listener.** The runner opens an outbound TLS WebSocket and
  exposes no inbound listener; commands return through that established connection.
- **Declared actions only.** Cloud input is limited to typed, schema-bounded
  arguments. The runner rejects unknown actions and arguments.
- **Content-addressed packs.** The control plane pins the trusted pack hash; the
  runner recomputes it from disk before execution. New or changed custom packs
  wait for trust.
- **Policy before side effects.** Runner scope, risk policy, action overrides,
  standing grants, and conditional approval are evaluated before dispatch.
- **Host-side enforcement.** The runner clamps execution options to the pack's
  limits and runs the declared binary and argv. Runner output is redacted before
  leaving the host; Emisar retains the resulting redacted output in audit log.
- **Two records.** The control-plane audit includes denied and pending requests;
  every runner also writes its execution attempts and local refusals to a
  hash-chained JSONL journal.
- **Optional bridge-attested dispatch.** A runner can require an Ed25519 intent
  signed by the customer-authorized MCP bridge, so the control plane cannot
  originate or widen a permitted call.

Read the exact guarantees, limitations, and threat model in
[`.agent/kb/specs/security-model.md`](.agent/kb/specs/security-model.md).

## What emisar is not

- It is not a sandbox or process isolator. We recommend using one, such as
  [coop](https://github.com/AndrewDryga/coop).
- It is not a generic `execute(command)` tool or a replacement for SSH.
- It does not replace OS least privilege, change management, or configuration
  management.
- It does not make a permitted destructive action harmless. The safety boundary
  is only as strong as the actions, pack trust, policy, runner configuration,
  and host permissions in use.

The staging-only `shell` pack is the explicit break-glass exception to the
declared-action model. It is critical-risk, default-denied, never suggested,
and should not be installed on production runners.

## Find the right surface

| Goal | Start here |
| --- | --- |
| Install, upgrade, harden, or diagnose a host | [`runner/README.md`](runner/README.md) |
| Connect Claude, ChatGPT, Cursor, Codex, or another MCP client | [Connect an LLM](https://emisar.dev/docs/connect-an-llm) |
| Inspect or develop the stdio bridge | [`mcp/README.md`](mcp/README.md) |
| Browse, install, or author action packs | [`packs/README.md`](packs/README.md) |
| Let an agent install emisar, connect a client, or author a pack | [`skills/README.md`](skills/README.md) |
| Review architecture and trust boundaries | [`.agent/kb/architecture.md`](.agent/kb/architecture.md) |
| Review protocol contracts | [`.agent/kb/specs/wire-protocol.md`](.agent/kb/specs/wire-protocol.md) and [`.agent/kb/specs/mcp-api.md`](.agent/kb/specs/mcp-api.md) |
| Contribute to the control plane | [`portal/README.md`](portal/README.md) |
| Review the production GCP infrastructure | [`infra/README.md`](infra/README.md) |

## Repository layout

```text
portal/   Elixir/Phoenix control plane, operator console, website, and MCP API
runner/   Go host runner and operator CLI
mcp/      Go stdio-to-HTTP MCP bridge
packs/    Versioned action-pack catalog
skills/   Standalone customer skills for coding agents
infra/    Production Terraform for emisar on Google Cloud
run       Root contributor command for development, tests, gates, and operations
dev/      Development Compose topologies, images, configs, and fixtures
tools/    Go implementations behind the contributor command and CI
dist/     Tracked distribution packages plus ignored generated build output
.agent/kb/ Repository architecture, specifications, runbooks, and rules
```

Each top-level project has its own `AGENTS.md` with its architecture, security
rules, and verification gate. Run `./run help` for the complete contributor
command surface.

## Develop locally

The recommended path needs only [Coop](https://coop.dryga.com) and Docker on
the host. It installs every repository pin in the isolated project image:

```sh
./run bootstrap             # works before Go is installed
coop build                  # build the pinned project image once
coop run -- ./run setup     # sidecars, deps, migrations, browser tooling
coop shell                  # enter the development box
```

Then, inside the shell:

```sh
./run seed        # explicit, idempotent demo data
./run serve       # live reload at the URL printed by Coop
# or: ./run serve --iex
```

For native development, install the exact versions in `.tool-versions` with
asdf, plus Git, Coop, Docker, the PostgreSQL client, ShellCheck,
Chrome/Chromium, and ImageMagick.
`./run setup` validates all prerequisites before starting services; `./run
doctor` reports every detected version and an actionable mismatch. On macOS,
run `./run certs trust` once for this workspace after setup.

The fast loop runs Phoenix in the current environment and keeps only PostgreSQL
and Keycloak in the workspace-isolated Coop dependency stack.

`./run urls` prints this workspace's distinct Portal, metrics, Postgres, and
Keycloak URLs. Coop forks inherit the same setup but receive different ports and
volumes. Seeds are never applied by setup, serve, or reset unless explicitly
requested.

Use `./run status` for a read-only view of the current workspace, `./run logs
[db|keycloak]` for its exact sidecar logs, and `./run psql` for its development
database. Every canonical gate prints its current phase and elapsed time; a
failure names the phase that stopped it.

The root `docker-compose.yml` remains the slower packaged topology with the
release Portal image, seeded demo data, three runners, MCP, and signing. Start it
with `./run smoke`; it serves <http://localhost:4010>. See
[`portal/README.md`](portal/README.md) and [`dev/README.md`](dev/README.md).

## License

This repository is dual-licensed:

- `runner/`, `mcp/`, and `packs/` are open source under the
  [Apache License 2.0](runner/LICENSE). You can inspect, build, package, and
  operate the on-host components independently.
- Everything else, including `portal/`, is source-available under the
  [Business Source License 1.1](LICENSE.md). Non-production use is free.
  Production use is permitted only as needed to operate the Apache-licensed
  components or the hosted service under the Additional Use Grant; other
  production use requires a commercial license. Each version converts to
  Apache 2.0 on its Change Date.

See [contributing](.github/CONTRIBUTING.md), [security](.github/SECURITY.md),
and [the CLA](.github/CLA.md). For commercial licensing, contact
`licensing@emisar.dev`.
