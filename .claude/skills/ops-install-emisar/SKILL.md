---
name: ops-install-emisar
description: Install, configure, repair, and certify Emisar runner and MCP bridge environments end to end. Use for customer onboarding, first-run setup, runner or MCP installation, pack selection and credentials, client registration, upgrades, migration to a supervised service, or any request to diagnose and report the health of an Emisar installation across the host, control plane, registry, fleet, MCP client, action execution, and audit trail.
effort: high
argument-hint: "[target host or environment]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Install and certify Emisar

Treat onboarding as a security-sensitive production change. Complete the
installation, prove every available layer, repair failures, and return one
evidence-backed health report. Do not stop after printing commands unless the
target or a required credential is genuinely unavailable.

## Read current contracts

From the repository root, read `AGENTS.md`, `runner/AGENTS.md`, `mcp/AGENTS.md`,
and `packs/AGENTS.md`. Then verify the current interfaces from these sources:

- `install.sh --help` and `runner/README.md` for runner platforms and lifecycle;
- `install-mcp.sh --help`, `mcp/README.md`, and installed `emisar-mcp --help` for
  bridge and client setup;
- installed `emisar pack --help`, `emisar doctor --help`, and
  `docs/mcp-api-spec.md` for packs, diagnostics, and the current MCP tools.

Never reconstruct a command from memory when its current help or source is
available. If the checkout and the installed binary disagree, stop and explain
the version skew before changing the host.

## Non-negotiable safety

- Treat runner bootstrap keys, MCP API keys, OAuth tokens, pack credentials,
  signing keys, and certificates as secrets. Never print them, commit them, put
  them in a report, or embed their literal values in shell history. Redact
  command output before quoting it.
- Use only the repository's HTTPS `install.sh` and `install-mcp.sh`. They verify
  release checksums and activate binaries atomically. Do not write another
  installer, silently build from source, or use an untrusted mirror.
- Prefer pinned `runner-vX.Y.Z` and `mcp-vX.Y.Z` tags for repeatable automation.
  Verify a tag exists; never invent one. If installing latest interactively,
  record the exact installed versions in the report.
- Inventory an existing install before mutation. Record binary versions,
  service state, config path and permissions, pack inventory, and custom paths.
  Preserve and back up operator-owned config before editing it.
- Never install the `shell` pack on a production runner. Never broaden
  `execution.inherit_env`, runner OS privileges, policy, scope, or pack trust to
  make a check pass. Configure only what the selected packs require.
- Do not reuse a production `emk-` API key in an ephemeral bridge probe. The
  bridge owns durable key rotation. Test MCP through the persistent configured
  client and its normal credential store.
- Do not call a skipped or unsupported check healthy. Do not expose inaccessible
  runners or bypass a denial with SSH, shell commands, copied code, or a wider
  credential.

## 1. Discover the target

Run discovery on the target host, not merely on the workstation controlling it:

```sh
uname -s
uname -m
id
command -v systemctl || true
command -v launchctl || true
command -v emisar || true
command -v emisar-mcp || true
```

Also inspect `/run/systemd/system`, existing Emisar units, custom supervisor
definitions, config paths, and containers. Classify exactly one runner path:

| Target | Supported path |
| --- | --- |
| Linux amd64/arm64 with running systemd | Supervised production runner |
| macOS amd64/arm64 with launchd | Supervised dev/evaluation runner |
| Linux/macOS container, cloud shell, CI, or external supervisor | Binary-only `--no-service`; the owner must provide supervision |
| Another OS, architecture, or init system | `UNSUPPORTED`; do not improvise a production service |

Published installers support only Linux and macOS on amd64 or arm64. Go
cross-compilation does not make an unsupported service lifecycle supported.
The macOS installer runs the LaunchDaemon as root and is dev/evaluation only;
never certify that default as a production least-privilege deployment.

Collect, without echoing secret values:

- canonical portal origin and a fresh portal-generated runner enrollment key;
- runner group, role, and environment labels;
- selected MCP client and a scoped operator credential or its OAuth flow;
- desired packs, private registry origin if any, and pack-specific credentials;
- whether signed dispatch is intentionally required.

Use the portal's **Runners > Install** and **Agents** pages as the authoritative
credential and client-snippet sources. Ask only for missing inputs that cannot
be discovered safely.

## 2. Install the runner

Download the installer to a temporary file so its exit status is unambiguous.
Keep secret values in shell variables or a protected environment, not literals:

```sh
installer="$(mktemp)"
curl -fsSL "${EMISAR_URL%/}/install.sh" -o "$installer"
sudo env \
  EMISAR_URL="$EMISAR_URL" \
  EMISAR_AUTH_KEY="$EMISAR_AUTH_KEY" \
  RUNNER_GROUP="$RUNNER_GROUP" \
  RUNNER_ROLE="$RUNNER_ROLE" \
  RUNNER_ENVIRONMENT="$RUNNER_ENVIRONMENT" \
  bash "$installer" --version "$RUNNER_VERSION"
rm -f "$installer"
unset EMISAR_AUTH_KEY
```

Adapt only with flags confirmed by `install.sh --help`:

- Use `--no-service` for containers, CI, cloud shells, and externally supervised
  processes. State who owns restart, logs, and boot persistence.
- Use `--no-start` only when configuration must be completed before first
  registration.
- Use `--packs` or `EMISAR_PACKS` for unattended provisioning, always with an
  explicit reviewed list. An explicitly empty value means no packs.
- Omit `--packs` for an interactive host-matched recommendation. Review the
  recommendation before accepting it.
- Preserve custom `--bin-dir`, `--etc-dir`, `--data-dir`, `--log-dir`, and
  `--user` values discovered on an existing install.

Do not combine unattended `--yes` with an implicit pack set. After install,
verify the reported version from the installed path and confirm config,
credential, state, log, and pack paths have least-privilege ownership and modes.
The example uses a pinned version; omit the complete `--version` pair only when
latest was an explicit interactive choice. Always clean up the temporary script
and unset the bootstrap-key variable after failure as well as success.

## 3. Configure and prove packs

1. Run `emisar pack suggest --names-only` on the target. Reconcile suggestions
   with the host's actual services and the operator's intended scope.
2. For post-install packs, obtain each exact `content_hash` from the trusted
   portal catalog or operator-approved private catalog using a structured JSON
   parser. Install with `emisar pack install <id> --hash sha256:...`; never parse
   JSON with regex or accept an unreviewed custom pack hash.
3. Run `emisar pack info <id>` for every installed pack. Install missing host
   binaries deliberately. Put required secrets in the protected `runner.env`
   file and add only the named variables to `execution.inherit_env`.
4. Reload packs with the supported supervisor operation: `systemctl reload
   emisar`, `launchctl kill HUP system/com.emisar.runner`, or a controlled
   external-supervisor restart. Do not send an unverified signal to an unknown
   process.
5. Run `emisar pack list`, `emisar state`, and `emisar doctor` with the exact
   installed config path and service environment. `doctor` must complete; its
   missing action tools are real degraded pack capabilities, not harmless
   noise.
6. Run `emisar pack update --dry-run`. Report drift; do not update outside the
   requested install or upgrade scope.

Use each pack's `setup.verify` action as its functional check. Inspect it through
`get_action`, use exact returned refs and argument schema, and dispatch it
through MCP only when it is low-risk and its required arguments are known.
Never invent arguments. A selected pack is not fully healthy until its verify
action succeeds on its intended runner; otherwise report the precise failure or
why the check was skipped.

## 4. Install and register MCP

Install into a system path or a user-writable path confirmed to be on the MCP
client's executable path:

```sh
installer="$(mktemp)"
curl -fsSL "${EMISAR_URL%/}/install-mcp.sh" -o "$installer"
bash "$installer" --version "$MCP_VERSION" --install-dir "$INSTALL_DIR"
rm -f "$installer"
"$INSTALL_DIR/emisar-mcp" --version
```

Use `sudo` only for a protected system install directory. Configure the chosen
client from the portal-generated snippet or the newly installed binary's
`--help`; use the absolute binary path and set `EMISAR_CLIENT` accurately. Do
not copy another client's syntax or add client-maintained action allowlists.
The portal owns the fixed MCP catalog and current runner scope.
Keep `<user-config-dir>/emisar/credentials/` durable and owner-only so automatic
API-key rotation survives restarts. Containerized clients must persist `/config`.
The example uses a pinned version; omit the complete `--version` pair only when
latest was an explicit interactive choice.

Restart or reload the real client, then test through that client:

1. Confirm `tools/list` exposes the fixed catalog documented in the current
   `docs/mcp-api-spec.md` (currently twelve tools).
2. Call `list_runners` with issues included; require the new runner to be
   `connected` with no unexplained issues.
3. Call `list_packs` with `availability: "all"`; reconcile every local pack and
   require intended packs/actions to be `executable` with no trust, retirement,
   descriptor, or deployment issue.
4. Call `find_actions` for a low-risk read-only host check, then `get_action` for
   the exact action, pack ref, schema, and runner ref. Prefer the installed
   pack's documented `setup.verify` action.
5. Call `run_action` with exact returned values and a clear onboarding reason.
   Follow `wait_for_run` through approval or delivery until terminal. Never
   auto-approve or widen policy. A policy denial is a valid enforcement result
   but a failed onboarding functional check.
6. Use `recent_runs` to prove the run is attributable to this client and target.

If MCP credentials or a client are intentionally absent, binary/version checks
may pass but authenticated MCP and action checks are `SKIPPED`, and the overall
installation cannot be certified end to end.

## 5. Verify every health plane

Run every applicable row independently. Keep liveness, readiness, registry,
runner connectivity, and action execution separate:

| Plane | Required evidence |
| --- | --- |
| Target | OS, arch, init/supervisor classification, UTC timestamp |
| Runner artifact | Absolute binary path and exact `emisar --version` |
| Runner service | Enabled/running state, stable restart count, recent redacted logs |
| Runner config | Exact config path, valid permissions, credential present without value |
| Runner preflight | Complete `emisar doctor` output and exit status |
| Portal liveness | `GET /healthz` succeeds and returns healthy JSON |
| Portal readiness | `GET /readyz` independently succeeds and returns healthy JSON |
| Registry | Configured catalog and suggestion endpoints return valid bounded JSON |
| Local packs | `pack list`/`state`, hashes, required tools/env allowlist, dry-run drift |
| Fleet state | MCP `list_runners`; connected runner and issue list |
| Pack trust | MCP `list_packs availability=all`; exact refs executable, no issues |
| MCP artifact/client | Bridge version, persistent client registration, fixed tool catalog |
| Functional action | Low-risk verify run reaches terminal success through MCP |
| Audit | `emisar audit verify` passes and `recent_runs` contains the same run |
| Signed dispatch | Only when configured: enforcing runner accepts the intended signed client and rejects unsigned dispatch |

Use `curl -fsS` with bounded timeouts for HTTP probes. Validate JSON with a
structured parser and retain only non-secret evidence. For a binary-only runner,
prove the external supervisor or foreground process is actually running; the
mere presence of a binary is insufficient.

Repair concrete failures and rerun the affected row plus downstream rows. Do
not hide intermittent results: record the failed attempt, remediation, and final
result. Stop only when required rows pass or an external owner must supply a
credential, approval, supported host, or service dependency.

## Report

Return one concise table with these states:

- `PASS` - check ran and met its contract;
- `DEGRADED` - core works, but a named optional capability is impaired;
- `FAIL` - a required check ran and failed;
- `SKIPPED` - check could not run; name the missing prerequisite and owner;
- `UNSUPPORTED` - no supported product path exists for this environment.

Use this shape:

```text
Emisar onboarding health - <target> - <UTC timestamp>
Overall: PASS | DEGRADED | FAIL | NOT CERTIFIED

Plane              State       Evidence
target             PASS        ...
runner artifact    PASS        ...
...

Installed: runner <version>; MCP <version>; packs <id@version/hash, ...>
Functional proof: <action, runner_ref, run_id, terminal status>
Remediated: <what changed and why, or none>
Open items: <owner + exact next action, or none>
```

Overall is `PASS` only when every applicable required row passes. Any required
`FAIL` makes it `FAIL`; any required `SKIPPED` or `UNSUPPORTED` makes it `NOT
CERTIFIED`. Use `DEGRADED` only for explicitly optional pack capabilities after
runner, portal, registry, MCP, functional execution, and audit all pass.

Include exact versions, paths, endpoint origins, pack refs, runner refs, run IDs,
timestamps, and sanitized error text. Never include credential values, complete
environment dumps, signing material, or raw logs that may contain secrets.
