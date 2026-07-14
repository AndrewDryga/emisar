# Runner

The runner is the on-host `emisar` binary. It loads versioned action packs,
dials out to the control plane, re-validates every request against the local
action schema, executes with the permissions of its service user, redacts
output before transmission, and writes a hash-chained local journal. It has no
inbound network listener.

System boundaries and the end-to-end request flow are documented in
[`docs/architecture.md`](../docs/architecture.md). The websocket messages are
versioned in [`docs/wire-protocol.md`](../docs/wire-protocol.md).

## Installing and running

The runner is intended to run as a long-lived background service on the
host it manages. Two supervised configurations are supported:

- **Linux + systemd** — production target. Hardened unit, dedicated
  service user, `Restart=on-failure` supervision with burst caps.
- **macOS + launchd** — dev/eval target. `LaunchDaemon` with
  `KeepAlive` + `ThrottleInterval`.

Other init systems (OpenRC, runit, s6) are not part of the installer.
The systemd unit is concise enough to translate by hand.

## One-line install

```sh
curl -sSL https://raw.githubusercontent.com/andrewdryga/emisar/main/install.sh | sudo bash
```

This installs the latest tagged release. To pin a specific version:

```sh
curl -sSL https://raw.githubusercontent.com/andrewdryga/emisar/main/install.sh \
  | sudo bash -s -- --version runner-v0.9.1 --yes
```

The portal's **Runners → Install** page generates this one-liner with
the control-plane URL and a fresh bootstrap key already baked in:

```sh
curl -sSL https://emisar.dev/install.sh | sudo EMISAR_AUTH_KEY=emkey-auth-... bash
```

`EMISAR_URL` / `EMISAR_AUTH_KEY` provided as env vars are written into
`config.yaml` / `runner.env` at install time, so the service starts
connected — no post-install editing. Other accepted env/flags:
`--packs LIST` (fixed pack set, no prompts), `--no-start` (install +
enable, don't start), `--no-service` (binary only — containers/CI),
`--bin-dir`/`--etc-dir`/`--data-dir`/`--log-dir`, `--user NAME`, and
`RUNNER_GROUP`/`RUNNER_ROLE`/`RUNNER_ENVIRONMENT` to pre-fill the
config's group + labels.

The script is idempotent: re-running upgrades in place. It is the
*only* component that needs network access during install (binary +
checksum from GitHub releases).

## What the installer does

1. Detects OS (`linux` / `darwin`) and arch (`amd64` / `arm64`).
2. Resolves the release tag (latest by default) and downloads the
   matching tarball from GitHub releases.
3. **Verifies SHA256** against the `SHA256SUMS` file published with
   the release. Aborts on mismatch.
4. **Linux only:** creates a system user `emisar` (via `useradd
   --system`, no shell, no home).
5. Installs the binary at `/usr/local/bin/emisar`.
6. Creates directories:
   - `/etc/emisar/` — config (`config.yaml`, `runner.env`, `packs/`).
   - `/var/lib/emisar/` — state (the per-runner token, work dir).
   - `/var/log/emisar/` — JSONL security log + rotated backups.
7. Drops a `config.yaml` skeleton **only if one does not already
   exist**. Existing configs are preserved on upgrade.
8. Drops a `runner.env` stub (`chmod 600`) for the auth key and pack
   credentials — **only if one does not already exist**, so an upgrade
   never clobbers tokens you've added.
9. Installs a small, host-matched set of starter packs after a confirmation
   prompt — always `linux-core` + `debugging`, plus `systemd-deep` / `debian`
   / `dnf-rpm` / `docker` when the matching tooling is present. The rest of the
   catalog is added on demand with `emisar pack install <name>`; subsequent
   installs leave existing packs alone. Setting `EMISAR_PACKS` (or `--packs`),
   even to an empty string, makes the set explicit instead: the installer
   installs exactly those packs (possibly none) and skips host detection and
   suggestions.
10. Installs the supervisor unit:
    - Linux: `/etc/systemd/system/emisar.service`, enabled but not
      started until you configure the auth key.
    - macOS: `/Library/LaunchDaemons/com.emisar.runner.plist`,
      registered with launchd. A root-owned `/etc/emisar/run-launchd.sh`
      wrapper loads the protected `runner.env` before it replaces itself with
      the runner; launchd has no `EnvironmentFile` equivalent.
11. On upgrades (where `config.yaml` already exists with a valid auth
    key configured), restarts the service.

## After install

1. **Edit `/etc/emisar/config.yaml`** — set `runner.group` (the cloud
   UI's auto-grouping key) and `cloud.url`.
2. **Edit `/etc/emisar/runner.env`** — set `EMISAR_AUTH_KEY=emkey-auth-...`
   (the cloud-issued bootstrap key for this runner).
3. **Start the service:**
   ```sh
   sudo systemctl start emisar        # Linux
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.emisar.runner.plist  # macOS
   ```
4. **Verify it's healthy:**
   ```sh
   sudo systemctl status emisar       # Linux
   sudo journalctl -u emisar -f       # Linux: follow logs
   tail -f /var/log/emisar/emisar.err.log   # macOS
   ```
5. **Confirm the security log is being written:**
   ```sh
   sudo emisar --config /etc/emisar/config.yaml events tail
   ```

## Pack authentication (`runner.env` + `inherit_env`)

Some packs reach a service that needs credentials — a token, password, or
address. Actions read these from the runner's **environment** (never from the
call arguments, so the secret never reaches the cloud). Two steps:

1. **Put the value in `/etc/emisar/runner.env`** — the `chmod 600` secrets
   file the service loads at start. Shell-style `KEY=VALUE`, no quotes:

   ```sh
   NOMAD_ADDR=http://127.0.0.1:4646
   NOMAD_TOKEN=<acl-token>
   ```

2. **Allowlist each name in `/etc/emisar/config.yaml`** under
   `execution.inherit_env` — the runner only forwards listed variables into an
   action's process:

   ```yaml
   execution:
     inherit_env:
       - NOMAD_ADDR
       - NOMAD_TOKEN
   ```

   The list is merged with the always-on defaults (`PATH`, `LANG`, `LC_ALL`,
   `TERM`), so list only the additional variables the pack needs.

Restart so both files are re-read: `sudo systemctl restart emisar`. What a pack
needs is in its setup notes (`emisar pack info <id>`). Re-running the installer
never overwrites `runner.env` or `config.yaml`, so these survive upgrades.

## Supervision behaviour

### Linux (systemd)

The bundled unit uses `Restart=on-failure` with `StartLimitBurst=5`
and `StartLimitIntervalSec=300`. Meaning:

- A clean `SIGTERM` (e.g., `systemctl stop emisar`) does not trigger
  restart.
- A panic, OOM, or non-zero exit triggers restart after a 5-second
  delay.
- After 5 restarts in 5 minutes the unit goes into a `failed` state
  and stops trying. The operator must run `systemctl reset-failed
  emisar && systemctl start emisar` to retry. This prevents a
  misconfigured runner (e.g., revoked auth key returning 401) from
  hammering the cloud forever.

`TimeoutStopSec=7m` gives the runner up to 7 minutes for graceful
shutdown before systemd SIGKILLs it. That window covers the bundled
`cassandra.nodetool_repair`'s 5-minute `cancel_grace`. If you add
actions with longer grace windows, raise `TimeoutStopSec` to match.

### macOS (launchd)

The bundled plist uses `KeepAlive` with `SuccessfulExit=false` plus
`Crashed=true`. Equivalent to systemd's `Restart=on-failure`. The
`ThrottleInterval=5` matches systemd's `RestartSec=5s`. `ExitTimeOut=420`
is the SIGTERM → SIGKILL window (7 minutes, same reasoning). The installer runs
the LaunchDaemon as root and supports macOS for development and evaluation, not
production; create a dedicated `_emisar` user and review its permissions before
using a custom macOS deployment. Update the plist plus the wrapper, config,
secret, state, and log ownership as one change; changing only `UserName` leaves
the daemon unable to read `runner.env`.

## Useful commands

| What                                  | Linux                                                | macOS                                                       |
| ------------------------------------- | ---------------------------------------------------- | ----------------------------------------------------------- |
| Start                                 | `sudo systemctl start emisar`                        | `sudo launchctl bootstrap system /Library/LaunchDaemons/com.emisar.runner.plist` |
| Stop                                  | `sudo systemctl stop emisar`                         | `sudo launchctl bootout system /Library/LaunchDaemons/com.emisar.runner.plist` |
| Restart                               | `sudo systemctl restart emisar`                      | (bootout + bootstrap)                                       |
| Status                                | `sudo systemctl status emisar`                       | `sudo launchctl print system/com.emisar.runner`              |
| Follow logs                           | `sudo journalctl -u emisar -f`                       | `tail -f /var/log/emisar/emisar.err.log`                    |
| Reload packs (no restart)             | `sudo systemctl kill -s HUP emisar`                  | `sudo launchctl kill HUP system/com.emisar.runner`           |
| Inspect local security log            | `sudo emisar --config /etc/emisar/config.yaml events tail` | same                                                  |
| List loaded actions                   | `sudo emisar --config /etc/emisar/config.yaml action list` | same                                                  |

## Upgrade

Re-run the installer with the new version. The service is stopped,
the binary replaced, the service restarted. Configs and packs are
untouched.

```sh
curl -sSL https://raw.githubusercontent.com/andrewdryga/emisar/main/install.sh \
  | sudo bash -s -- --version runner-v0.9.1 --yes
```

## Uninstall

```sh
sudo bash install.sh --uninstall            # binary + service unit only
sudo bash install.sh --uninstall --purge    # plus /etc/emisar, /var/lib, /var/log
```

`--purge` also deletes the local security log; only do this if you've
already shipped the log to wherever you want it preserved.

## Air-gapped install

Download the release tarball directly:

```sh
curl -LO https://github.com/andrewdryga/emisar/releases/download/runner-v0.9.1/emisar-0.9.1-linux-amd64.tar.gz
curl -LO https://github.com/andrewdryga/emisar/releases/download/runner-v0.9.1/SHA256SUMS
sha256sum -c SHA256SUMS
tar xzf emisar-0.9.1-linux-amd64.tar.gz
sudo bash emisar-0.9.1-linux-amd64/install.sh --yes
```

The tarball contains a copy of `install.sh` that pins to its own
version — running it does not re-fetch from GitHub.

## Why these specific patterns

- **No `curl | sudo bash` without HTTPS + a tagged release.** The
  installer always pulls from GitHub releases over TLS; the SHA256
  verification step closes the gap if the network is compromised.
- **`Restart=on-failure` not `Restart=always`.** Clean shutdowns
  (operator-initiated, planned restarts) should stay shut down. Only
  crashes warrant restart.
- **`StartLimitBurst=5`.** Without it, a broken auth key produces an
  infinite 401-reconnect loop. With it, the runner fails closed after 5
  attempts and surfaces a clear error in `systemctl status`.
- **Minimal default sandbox.** The unit only sets `User=emisar` and
  `RestrictSUIDSGID=yes` beyond the supervision basics. emisar is a
  sysadmin's deputy — actions are intentionally permissioned by the
  operator. See the next section if you want defense-in-depth on top.

## Signed dispatch (optional)

To make this runner run **only** actions a real person signed in their MCP
client — so even a compromised control plane can't dispatch to it — run
`emisar signing init` to mint an offline CA plus an operator certificate, add the
CA's public key under `signing.trusted_cas` in `config.yaml`, and give the leaf
key and certificate to the MCP client. Full setup, scoping, rotation, and
troubleshooting: [`docs/signed-dispatch.md`](../docs/signed-dispatch.md).

## Hardening (optional)

The default systemd unit is deliberately minimal. Every
`Protect*=yes` / `Restrict*=yes` directive in systemd propagates to
the service's child processes — which means it propagates to every
action the runner runs. Aggressive sandboxing fights the operator:

| Directive                       | What it would break                         |
| ------------------------------- | ------------------------------------------- |
| `ProtectSystem=strict`          | Actions writing outside `/var/lib/emisar`   |
| `ProtectHome=yes`               | Actions reading `/home/<user>/...`          |
| `NoNewPrivileges=yes`           | Actions calling `sudo` for elevated work    |
| `ProtectProc=invisible`         | `ps -ef`, `top`, scanning `/proc/<pid>`     |
| `PrivateDevices=yes`            | Actions touching `/dev/sda`, `/dev/loop*`   |
| `ProtectKernelTunables=yes`     | `sysctl -w`                                 |
| `ProtectKernelLogs=yes`         | `dmesg`                                     |
| `MemoryDenyWriteExecute=yes`    | Any JIT (Java, Node, LuaJIT, some Python)   |
| `RestrictNamespaces=yes`        | `unshare`, container-aware actions          |

Operators who want these *on top of* the default — for sites that
strictly limit what their action packs can do — can drop in an
override file. Drop-ins survive `install.sh` upgrades.

```sh
sudo mkdir -p /etc/systemd/system/emisar.service.d
sudo tee /etc/systemd/system/emisar.service.d/harden.conf <<'EOF'
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/emisar /var/log/emisar
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
EOF
sudo systemctl daemon-reload
sudo systemctl restart emisar
```

This is the full hardened stance that earlier emisar versions
shipped as the default. Use it when you know the action packs you
ship don't need any of the capabilities above. Run `systemctl cat
emisar` to confirm the merged unit looks right.

## Granting elevated privileges to specific actions

Most ops actions need root-or-similar privileges (`systemctl
restart`, `iptables -L`, reading `/var/log/auth.log`). The emisar
runner user is unprivileged by default, so you grant just what each
action needs via the OS's normal mechanisms.

### Polkit (preferred for systemd actions)

```sh
sudo tee /etc/polkit-1/rules.d/50-emisar.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.user == "emisar") {
        var unit = action.lookup("unit");
        if (unit == "nginx.service" || unit == "cassandra.service") {
            return polkit.Result.YES;
        }
    }
});
EOF
```

`systemctl restart nginx` from the emisar user now works without a
password, but only for the listed units.

### sudoers (for non-systemd commands)

```sh
sudo tee /etc/sudoers.d/emisar <<'EOF'
emisar ALL=(root) NOPASSWD: /usr/sbin/iptables -L*, /usr/bin/journalctl -u *
EOF
sudo chmod 0440 /etc/sudoers.d/emisar
sudo visudo -c -f /etc/sudoers.d/emisar
```

If you go this route, action YAML calls `sudo` explicitly:

```yaml
execution:
  command:
    binary: sudo           # bare name — resolved via PATH
    argv:
      - "-n"
      - "/usr/sbin/iptables"   # absolute here: sudoers rules match full paths
      - "-L"
```

### Run as root

For dev / experimentation only — flips the boundary off entirely:

```sh
sudo mkdir -p /etc/systemd/system/emisar.service.d
sudo tee /etc/systemd/system/emisar.service.d/root.conf <<'EOF'
[Service]
User=root
Group=root
EOF
sudo systemctl daemon-reload
sudo systemctl restart emisar
```

Don't do this in production. If the runner is compromised, attacker
has root. The whole point of the unprivileged-user default is to
make a compromised runner process a small footprint, not a
full-system takeover.

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

The CLI commands live at the module root. Runtime packages are under
`internal/`: `cloud` owns the websocket, `engine` the action pipeline,
`packs` loading and hashes, `validation` schemas, `executor` process control,
`redact` streaming redaction, `admission` the host-local gate, and `audit` the
JSONL journal. Public manifest types live in `pkg/actionspec` and
`pkg/packspec`.
