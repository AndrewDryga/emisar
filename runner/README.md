# emisar runner

The runner is the local enforcement and execution layer for emisar. It loads
the action packs installed on a host, dials out to the control plane, and checks
every dispatched action against the local pack before it starts a process. It
has no inbound network listener.

Run one runner on every host that an agent should be able to inspect or change.
The runner uses the permissions of its service user; emisar does not turn a
permitted command into a sandbox.

## Install and prove it works

The supported production target is Linux with systemd. macOS with launchd is
available for development and evaluation.

1. In the emisar dashboard, choose **Connect a runner**. The generated command
   contains the control-plane URL and a fresh, single-use enrollment key.
2. Run that command on the host:

   ```sh
   curl -sSL https://emisar.dev/install.sh \
     | sudo EMISAR_ENROLLMENT_KEY=emkey-enroll-... EMISAR_URL=https://emisar.dev bash
   ```

   The installer verifies the release checksum, creates a dedicated `emisar`
   user on Linux, installs the service, adds host-matched starter packs, and
   starts the runner.
3. Verify the host and the control-plane connection:

   ```sh
   sudo emisar doctor
   sudo systemctl status emisar
   sudo journalctl -u emisar -f
   ```

4. Confirm the runner is online in the dashboard. Dispatch `linux.uptime` with
   a reason and check that the result appears in the audit trail.

`emisar doctor` is the first troubleshooting command. It checks configuration,
credentials, pack contents, required host binaries, and control-plane reachability
without opening a cloud session, and reports all failures in one run.

The complete operator walkthrough is at
[emisar.dev/docs/quickstart](https://emisar.dev/docs/quickstart). Container and
Kubernetes installations are covered at
[emisar.dev/docs/containers](https://emisar.dev/docs/containers).

## What the runner enforces

For every action, the runner:

1. Resolves the action from its own loaded pack catalog.
2. Recomputes the pack's content hash and compares it with the hash trusted by
   the control plane.
3. Re-validates every argument against the pack's typed schema and rejects
   unknown input.
4. Applies the host-local action allowlist, denylist, and optional risk ceiling.
5. Clamps timeout and output limits to the pack's declared bounds.
6. Executes the pack-authored binary and argv with `os/exec`.
7. Redacts output before it leaves the host.
8. Appends the attempt to a hash-chained local JSONL journal.

Fixed shell programs may be authored inside a pack when pipes or shell features
are needed, but cloud input is still limited to validated substitutions. The
staging-only `shell` pack is the explicit arbitrary-command exception and must
not be installed on production runners.

See the [security model](../docs/security-model.md),
[architecture](../docs/architecture.md), and
[runner wire protocol](../docs/wire-protocol.md) for the full contract.

## Files and configuration

The supervised installer uses these paths by default:

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/emisar` | Runner and operator CLI |
| `/etc/emisar/config.yaml` | Host identity, control-plane URL, packs, admission, and execution settings |
| `/etc/emisar/runner.env` | Mode-0600 enrollment key and pack credentials |
| `/etc/emisar/packs/` | Installed action packs |
| `/var/lib/emisar/` | Per-runner token, work files, and durable execution state |
| `/var/log/emisar/events.jsonl` | Hash-chained local security journal |

The portal-generated install command writes the URL and enrollment key for you.
For manual provisioning, the minimum shape is:

```yaml
schema_version: 1

runner:
  group: web-prod
  labels:
    region: us-east-1
    environment: prod

cloud:
  url: wss://emisar.dev
  enrollment_key_env: EMISAR_ENROLLMENT_KEY
  token_path: /var/lib/emisar/token.json

paths:
  data_dir: /var/lib/emisar
  work_dir: /var/lib/emisar/work
  packs:
    - /etc/emisar/packs

execution: {}

events:
  jsonl_path: /var/log/emisar/events.jsonl
```

Groups and labels organize the fleet and participate in scoping. Treat their
names as durable operational identifiers. The full annotated configuration is
[`examples/config.yaml`](examples/config.yaml).

## Pack credentials

Pack credentials stay on the host. They are never passed as action arguments.

1. Put each value in `/etc/emisar/runner.env`:

   ```sh
   NOMAD_ADDR=http://127.0.0.1:4646
   NOMAD_TOKEN=<acl-token>
   ```

2. Allowlist the variable names in `/etc/emisar/config.yaml`:

   ```yaml
   execution:
     inherit_env:
       - NOMAD_ADDR
       - NOMAD_TOKEN
   ```

3. Restart the service so both files are re-read:

   ```sh
   sudo systemctl restart emisar
   ```

The runner always provides `PATH`, `LANG`, `LC_ALL`, and `TERM`; everything
else is dropped unless it is allowlisted. Run `emisar pack info <id>` to see a
pack's binaries, environment variables, privilege needs, and verification
action. The installer preserves both configuration files during upgrades.

## Install and manage packs

The installer adds a small host-matched starter set. Add capabilities by name
from the public registry, by pinned version, from a local directory, or from an
HTTPS tarball:

```sh
sudo emisar pack install redis
sudo emisar pack install redis=0.2.3 --hash sha256:...
sudo emisar pack install ./my-pack
sudo emisar pack info redis
```

The runner validates every pack before installing it. When a daemon is running,
pack install, update, and uninstall signal it to reload and re-advertise without
dropping in-flight work. Otherwise run `sudo systemctl reload emisar`.

Browse the catalog at [emisar.dev/packs](https://emisar.dev/packs) and read the
[pack guide](../packs/README.md) before installing capabilities on production
hosts.

## Local admission

Admission is the host's defense-in-depth gate. It hides and refuses actions
that should never be available on that runner, even if the control plane asks
for one.

```yaml
admission:
  allow:
    - "linux.*"
    - "postgres.uptime"
  deny:
    - "*.repair"
    - "linux.systemctl_restart"
  max_risk: medium
```

An action must match `allow` when that list is present, must not match `deny`,
and must not exceed `max_risk`. Empty admission settings accept every action in
the locally installed catalog.

## Operations

| Task | Linux | macOS |
| --- | --- | --- |
| Start | `sudo systemctl start emisar` | `sudo launchctl bootstrap system /Library/LaunchDaemons/com.emisar.runner.plist` |
| Stop | `sudo systemctl stop emisar` | `sudo launchctl bootout system /Library/LaunchDaemons/com.emisar.runner.plist` |
| Restart | `sudo systemctl restart emisar` | bootout, then bootstrap |
| Status | `sudo systemctl status emisar` | `sudo launchctl print system/com.emisar.runner` |
| Follow logs | `sudo journalctl -u emisar -f` | `tail -f /var/log/emisar/emisar.err.log` |
| Reload packs and signing trust | `sudo systemctl reload emisar` | `sudo launchctl kill HUP system/com.emisar.runner` |
| Tail the local journal | `sudo emisar events tail` | `sudo emisar events tail` |
| Verify the journal chain | `sudo emisar audit verify` | `sudo emisar audit verify` |

The Linux unit uses `Restart=on-failure`, a five-attempt restart burst cap, and
a seven-minute graceful shutdown window. The cap prevents a bad or revoked
credential from causing an endless authentication loop. The shutdown window
covers the longest bundled cancellation grace.

The default 30-second heartbeat pairs with the portal's stale-socket watchdog
and connection lease. A half-open network path can take roughly 90-120 seconds
to release ownership before a replacement connection is accepted. Reducing the
runner's reconnect backoff does not bypass that safety window.

## Upgrade and remove

Re-run the installer to upgrade in place. Existing configuration, credentials,
and valid packs are preserved:

```sh
curl -sSL https://emisar.dev/install.sh | sudo EMISAR_PACKS="" bash -s -- --yes
```

Pin a reviewed release when repeatability matters:

```sh
curl -sSL https://emisar.dev/install.sh \
  | sudo EMISAR_PACKS="" bash -s -- --version runner-vX.Y.Z --yes
```

Unattended installs require an explicit pack set. The empty value above adds no
new packs and preserves valid packs already installed; pass reviewed pack IDs
instead when provisioning a new host. Interactive installs can leave the value
unset and review host-matched recommendations.

The installer bundled in a release tarball pins itself to that release and can
be moved to an offline host with the tarball and `SHA256SUMS` file.

To remove the service while retaining configuration and local evidence:

```sh
sudo bash install.sh --uninstall
```

The default uninstall deletes the cached runner token and generated
`runner_id`. It keeps `/etc/emisar`, the dispatch journal and signing nonces in
`/var/lib/emisar`, and `/var/log/emisar`. Add `--purge` only when those retained
files should also be deleted. The enrollment key and pack secrets in
`runner.env` are therefore retained without `--purge`. Preserve or export the
local journal first.

When an upgrade supplies a different `EMISAR_ENROLLMENT_KEY`, the installer
updates that line in `runner.env` and asks whether the host should get a new
runner identity. Answer no to re-register the existing identity with the new
key. Answer yes to delete the cached token and `runner_id` before restart.
Unattended installs preserve identity unless `--reset-identity` is explicit.

To perform the identity reset manually on a default systemd install, put the
new enrollment key in `/etc/emisar/runner.env`, then run:

```sh
sudo systemctl stop emisar
sudo rm -f /var/lib/emisar/token /var/lib/emisar/token.json \
  /var/lib/emisar/runner_id
sudo systemctl start emisar
```

For custom installs, remove the configured `cloud.token_path` and
`<paths.data_dir>/runner_id` instead. Delete the old runner in the dashboard
first when replacing it in the same account; runner names must be unique.

## Signed dispatch (optional)

A runner can require every action to carry an Ed25519 intent signed by the MCP
client. The control plane can relay that action but cannot originate it, change
its exact arguments, or widen its runner set.

Run `emisar signing init`, add the generated CA public key under
`signing.trusted_cas`, and configure the MCP client with the leaf key and
certificate. Setup, scope, rotation, replay protection, and refusal codes are in
[`docs/signed-dispatch.md`](../docs/signed-dispatch.md).

## Hardening (optional)

The installed systemd unit is deliberately modest because every service
sandbox directive also constrains the actions it launches. For example:

| Directive | Common consequence |
| --- | --- |
| `ProtectSystem=strict` | Blocks actions that write outside declared writable paths |
| `ProtectHome=yes` | Blocks reads under `/home` |
| `NoNewPrivileges=yes` | Blocks actions that use `sudo` |
| `ProtectProc=invisible` | Breaks process and `/proc` diagnostics |
| `PrivateDevices=yes` | Blocks storage and device actions |
| `MemoryDenyWriteExecute=yes` | Breaks JIT runtimes |

Add a systemd drop-in only after checking every installed pack against the
restrictions. Drop-ins survive installer upgrades. A strong read-mostly host
profile can start with:

```ini
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/emisar /var/log/emisar
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
```

Install it under `/etc/systemd/system/emisar.service.d/harden.conf`, run
`sudo systemctl daemon-reload`, restart the service, and use `emisar doctor`
plus representative local action runs to prove the profile fits the host.

## Granting elevated privileges to specific actions

The default Linux service user is unprivileged. Grant only the OS authority
required by the packs installed on that host.

For systemd actions, prefer a narrow polkit rule:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.user == "emisar") {
        var unit = action.lookup("unit");
        if (unit == "nginx.service" || unit == "cassandra.service") {
            return polkit.Result.YES;
        }
    }
});
```

For other commands, a sudoers rule must match the exact binary and bounded argv
shape used by the action:

```sudoers
emisar ALL=(root) NOPASSWD: /usr/sbin/iptables -L*, /usr/bin/journalctl -u *
```

Validate it with `visudo -c -f /etc/sudoers.d/emisar`. Do not run the service as
root in production; that turns a runner compromise into full host compromise.

## Development

Build from the repository root:

```sh
(cd runner && go build -o ../bin/emisar .)
./bin/emisar --config ./runner/examples/config.yaml state
```

The module gate is:

```sh
cd runner
gofmt -l -s .
go vet ./...
go mod tidy && git diff --exit-code -- go.mod go.sum
go test -race -count=1 ./...
```

CLI commands live at the module root. Runtime packages are under `internal/`;
the public pack manifest types are in `pkg/actionspec` and `pkg/packspec`.
Read [`AGENTS.md`](AGENTS.md) before changing the execution or trust boundary.
