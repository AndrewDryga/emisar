---
name: install-emisar
description: Install, configure, repair, and certify the Emisar runner on a host end to end for customer onboarding. Use for first-run setup, runner installation, pack selection and credentials, upgrades, supervised-service migration, or any request to diagnose and report runner health across the host, control plane, registry, action execution, and audit trail. For connecting an LLM or MCP client, use the connect-llm skill.
---

# Install and certify the Emisar runner

Execute this workflow on the customer's target environment. Do not require an
Emisar source checkout, fork, build toolchain, repository instructions, or
internal contributor skill. Use the public HTTPS installers, the signed-in
Emisar portal, the installed CLIs, and public documentation.

Treat onboarding as a security-sensitive production change. Complete every
available check, repair concrete failures, and return one evidence-backed
health report. Do not stop after printing commands unless the target or a
required credential is genuinely unavailable.

## Use current public interfaces

Default to the hosted control plane at `https://emisar.dev`. Use a different
`EMISAR_URL` only when the operator identifies and trusts that deployment.

Verify commands before running them:

- Download `${EMISAR_URL%/}/install.sh` and run its local copy with `--help`.
- After installation, use `emisar --help`, `emisar pack --help`, and `emisar
  doctor --help` as the installed-version contracts.
- Use the signed-in **Runners > Install** page for current enrollment
  credentials.
- Use the public guides at `https://emisar.dev/docs/quickstart` and
  `https://emisar.dev/docs/action-packs` when more detail is needed.

Never reconstruct a flag or config shape from memory when current help or a
portal-generated snippet is available. If installed help differs from public
documentation, preserve the host, report the exact version skew, and follow the
installed artifact's contract unless this is an explicit upgrade.

## Safety rules

- Treat runner enrollment keys, MCP API keys, OAuth tokens, pack credentials,
  signing keys, and certificates as secrets. Never print, commit, report, or
  place their literal values in shell history. Sanitize captured output.
- Use only HTTPS installers from the operator-approved `EMISAR_URL`. They verify
  release checksums and activate binaries atomically. Do not silently build from
  source, write another installer, or use an untrusted mirror.
- Prefer a pinned `runner-vX.Y.Z` tag for repeatable automation.
  Verify a requested tag exists. For an interactive latest install, report the
  exact installed versions.
- Inventory an existing installation before changing it. Record versions,
  service state, config paths and permissions, packs, custom paths, and the
  current supervisor. Back up operator-owned config before editing it.
- Never install the `shell` pack on a production runner. Never broaden
  `execution.inherit_env`, OS privileges, policies, approvals, scopes, or pack
  trust merely to make a check pass.
- Never claim a skipped, intermittent, or unsupported check is healthy. Do not
  bypass a denial with SSH, copied shell commands, or a wider credential.

## 1. Discover the target

Run discovery on the actual target host:

```sh
uname -s
uname -m
id
command -v systemctl || true
command -v launchctl || true
command -v emisar || true
```

Inspect `/run/systemd/system`, existing Emisar units, launchd services, external
supervisor definitions, containers, config paths, and installed versions.
Classify exactly one runner path:

| Target | Supported path |
| --- | --- |
| Linux amd64/arm64 with running systemd | Supervised production runner |
| macOS amd64/arm64 with launchd | Supervised development/evaluation runner |
| Linux/macOS container, cloud shell, CI, or external supervisor | Binary-only `--no-service`; the owner provides supervision |
| Another OS, architecture, or init system | `UNSUPPORTED`; do not improvise a production service |

The macOS LaunchDaemon runs as root by default and is for development or
evaluation. Do not certify that default as a production least-privilege setup.

Collect without echoing secret values:

- control-plane origin and a fresh portal-generated runner enrollment key;
- runner group, role, and environment labels;
- desired packs, private registry origin if any, and pack credentials;
- whether signed dispatch is intentionally required.

Ask only for inputs that cannot be discovered safely.

## 2. Install the runner

Download first so failures are unambiguous and `--help` can be inspected. Keep
secrets in protected variables, never command literals:

```sh
EMISAR_URL="${EMISAR_URL:-https://emisar.dev}"
installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT HUP INT TERM
curl --fail --silent --show-error --location \
  "${EMISAR_URL%/}/install.sh" -o "$installer"
bash "$installer" --help
sudo env \
  EMISAR_URL="$EMISAR_URL" \
  EMISAR_ENROLLMENT_KEY="$EMISAR_ENROLLMENT_KEY" \
  RUNNER_GROUP="$RUNNER_GROUP" \
  RUNNER_ROLE="$RUNNER_ROLE" \
  RUNNER_ENVIRONMENT="$RUNNER_ENVIRONMENT" \
  bash "$installer" --version "$RUNNER_VERSION"
unset EMISAR_ENROLLMENT_KEY
rm -f "$installer"
trap - EXIT HUP INT TERM
```

This example assumes `RUNNER_VERSION` is a verified, nonempty pin. Omit the
complete `--version "$RUNNER_VERSION"` pair when installing latest was an
explicit interactive choice.

Adapt only with flags present in the downloaded installer's help:

- Use `--no-service` for containers, CI, cloud shells, and externally
  supervised processes. Identify who owns boot persistence, restart, and logs.
- Use `--no-start` only when configuration must finish before registration.
- Use `--packs` or `EMISAR_PACKS` for unattended provisioning with an explicit,
  reviewed list. An explicitly empty `EMISAR_PACKS` means no packs.
- Omit pack selection for interactive host-matched recommendations. Review
  recommendations before accepting them.
- Preserve discovered custom binary, config, data, log, and service-user paths
  on an existing install.

Do not use unattended `--yes` with an implicit pack set. Use `sudo` only when
the selected paths or supervisor require it. On failure, clean up the temporary
script and unset the enrollment key before doing anything else.

After installation, verify the binary from its absolute installed path, config
parsing, and least-privilege ownership/modes on config, credential, state, log,
and pack paths.

## 3. Configure and prove packs

1. Run `emisar pack suggest --names-only` on the target. Reconcile suggestions
   with actual host services and intended operator scope.
2. Obtain each exact `content_hash` from the trusted portal catalog or an
   operator-approved private catalog with a structured JSON parser. Install
   with `emisar pack install <id> --hash sha256:...`. Never parse catalog JSON
   with regex or accept an unreviewed custom hash.
3. Run `emisar pack info <id>` for every installed pack. Install missing host
   binaries deliberately. Put required secrets in the protected runner
   environment file and add only named variables to `execution.inherit_env`.
4. Reload with the installed supervisor's supported operation: `systemctl
   reload emisar`, `launchctl kill HUP system/com.emisar.runner`, or a controlled
   external-supervisor restart. Do not signal an unidentified process.
5. Run `emisar pack list`, `emisar state`, and `emisar doctor` with the actual
   config path and service environment. Missing action tools are degraded pack
   capabilities, not harmless noise.
6. Run `emisar pack update --dry-run`. Report drift; do not update outside an
   explicit install or upgrade scope.

Use each selected pack's `setup.verify` action as its functional check.
Dispatch it from the signed-in portal — open the runner, pick the action,
supply a clear onboarding reason — or, when the operator already has a
connected MCP client, resolve it with `get_action` and dispatch with the exact
returned refs. Run it only when it is low risk and every required argument is
known. Never invent arguments. A pack is healthy only when its verify action
succeeds on its intended runner; otherwise report the failure or exact reason
the check was skipped.

## 4. Verify every health plane

Run every applicable row independently. Liveness, readiness, registry access,
runner connectivity, and action execution are distinct checks:

| Plane | Required evidence |
| --- | --- |
| Target | OS, architecture, supervisor classification, UTC timestamp |
| Runner artifact | Absolute path and exact `emisar --version` |
| Runner service | Enabled/running state, stable restart count, recent sanitized logs |
| Runner config | Exact path, valid permissions, credential present without its value |
| Runner preflight | Complete `emisar doctor` result and exit status |
| Portal liveness | Bounded `GET ${EMISAR_URL%/}/healthz` returns healthy JSON |
| Portal readiness | Independent bounded `GET ${EMISAR_URL%/}/readyz` returns healthy JSON |
| Registry | `${EMISAR_URL%/}/packs.json`, `${EMISAR_URL%/}/packs/suggest.json`, and the configured registry catalog return valid bounded JSON |
| Local packs | Pack state, hashes, required tools/env allowlist, dry-run drift |
| Fleet state | The runner shows connected in the portal, with no unexplained issues |
| Pack trust | The Packs page shows the intended versions trusted, nothing pending or retired unexplained |
| Functional action | Low-risk verify run reaches terminal success |
| Audit | `emisar audit verify` passes and the portal audit shows the same run |
| Signed dispatch | When configured: a signed client's call succeeds and unsigned dispatch is rejected (needs a connected client — see the connect-llm skill) |

Use bounded HTTP timeouts and a structured JSON parser. Retain only non-secret
evidence. For a binary-only runner, prove its external supervisor or foreground
process is actually running; a binary on disk is not a running service.

Repair concrete failures, then rerun the affected row and every downstream row.
Record intermittent failures, remediation, and final results. Stop only when
required checks pass or an external owner must supply a credential, approval,
supported host, or service dependency.

## Report

Use only these states:

- `PASS`: the check ran and met its contract.
- `DEGRADED`: core operation passed, but a named optional capability is impaired.
- `FAIL`: a required check ran and failed.
- `SKIPPED`: the check could not run; name its missing prerequisite and owner.
- `UNSUPPORTED`: no supported Emisar path exists for the environment.

Return one concise report:

```text
Emisar onboarding health - <target> - <UTC timestamp>
Overall: PASS | DEGRADED | FAIL | NOT CERTIFIED

Plane              State       Evidence
target             PASS        ...
runner artifact    PASS        ...
...

Installed: runner <version>; packs <id@version/hash, ...>
Functional proof: <action, runner_ref, run_id, terminal status>
Remediated: <what changed and why, or none>
Open items: <owner + exact next action, or none>
```

Overall is `PASS` only when every applicable required row passes. A required
`FAIL` makes it `FAIL`; a required `SKIPPED` or `UNSUPPORTED` makes it `NOT
CERTIFIED`. Use `DEGRADED` only for optional pack capabilities after runner,
portal, registry, functional execution, and audit all pass.

Include exact versions, paths, endpoint origins, pack and runner refs, run IDs,
timestamps, and sanitized errors. Never include credential values, complete
environment dumps, signing material, or raw logs that may contain secrets.

When the runner is certified, connect the operator's LLM client next with the
`connect-llm` skill.
