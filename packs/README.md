# emisar action packs

An action pack is a versioned, content-addressed directory of declared
infrastructure operations. Each action fixes the binary, argv shape, typed
arguments, risk, limits, redaction, and side-effect description that the runner
will enforce.

Packs are how emisar adds capabilities without giving an agent a shell or
adding another MCP server. The catalog in this repository currently contains
**80 packs and 1,285 actions** across Linux, databases, containers,
orchestrators, cloud providers, networking, storage, runtimes, and
observability.

Browse the current catalog and every action at
[emisar.dev/packs](https://emisar.dev/packs).

## Install the packs a host needs

The runner installer suggests a small starter set from the binaries and
services detected on the host. Add another published pack by name:

```sh
sudo emisar pack install redis
sudo emisar pack info redis
```

`pack install` downloads the artifact, validates it, computes its content hash,
prints its setup requirements, and reloads a running runner. `pack info` shows
the required binaries and environment, risk profile, and a low-risk action to
use for verification.

For a repeatable rollout, pin both version and hash from the registry page:

```sh
sudo emisar pack install redis=0.2.3 --hash sha256:...
```

The same command accepts a local directory or an HTTPS tarball:

```sh
sudo emisar pack install ./my-pack
sudo emisar pack install https://registry.example.com/my-pack.tar.gz --hash sha256:...
```

Ship only the packs a host needs. A smaller local catalog reduces executable
surface and gives the agent a shorter list to reason over.

## Pack anatomy

```text
my-pack/
  pack.yaml
  actions/
    status.yaml
    restart.yaml
  scripts/            optional files executed by declared script actions
```

`pack.yaml` owns identity, version, descriptive metadata, setup requirements,
and the explicit action-file list. Each action YAML declares one operation.

A minimal action looks like this:

```yaml
schema_version: 1
id: web.service_status
title: Show service status
kind: exec
risk: low
description: Show the current systemd status for one approved web service.
side_effects:
  - Reads service state and recent status output.

args:
  - name: unit
    type: string
    required: true
    validation:
      enum: [nginx.service, caddy.service]

execution:
  command:
    binary: systemctl
    argv: [status, "{{ args.unit }}", --no-pager]
  timeout: 15s

output:
  parser: text
  max_stdout_bytes: 131072
  max_stderr_bytes: 8192
```

Actions that need a machine-readable result can opt in with a complete bounded
Draft 2020-12 object schema. This is legal only with `parser: json` and
`parser_required: true`. The runner redacts stdout first, strictly parses one
JSON object, validates it against the schema, and returns it only on success.
External references and schemas/results above the documented complexity and
8 KiB wire limits are rejected. Schema numbers must survive a float64 round
trip — an integer above 2^53 fails pack load and catalog build with the
canonical form to write instead — and `multipleOf` must be a positive integer.
See [`showcase.json_output`](showcase/actions/json_output.yaml) for the
executable reference.

The caller chooses `unit`; it cannot replace `systemctl`, add another flag, or
name a service outside the enum. The runner validates the same schema again on
the host before execution.

The complete schema, including paths, arrays, script actions, examples, output
parsers, execution users, and redaction, is at
[emisar.dev/docs/action-packs](https://emisar.dev/docs/action-packs). The
[`showcase` pack](showcase/) is the executable reference.

## Trust and drift

The runner computes a SHA-256 content hash from the complete pack. The control
plane pins the exact hash an administrator trusts, and the runner recomputes it
before every dispatch. A new, custom, or changed pack blocks until an admin
trusts that version and hash.

Official catalog versions can be auto-trusted because their bytes match the
catalog compiled into the portal release. Hand-editing the same version on one
host creates a different hash; the Packs page reports that as drift rather than
silently treating it as the published pack.

This is content integrity, not publisher identity. Trusting a hash means
trusting the action definitions, including their declared risk and side effects.
Review custom and third-party packs as code.

## Credentials stay on the runner

Packs do not carry credentials, and callers do not send credentials as action
arguments. The command-line tool named by an action reads its normal host-local
environment or configuration file.

Put required values in the runner's mode-0600 environment file:

```sh
PGHOST=postgres.internal
PGUSER=emisar
PGPASSWORD=<secret>
```

Then allowlist only the variable names the action process needs:

```yaml
execution:
  inherit_env:
    - PGHOST
    - PGUSER
    - PGPASSWORD
```

Restart the runner after changing its environment. `emisar pack info postgres`
reports required variables and flags names missing from `inherit_env` when a
runner config is available. File-based credentials such as a kubeconfig or
`.pgpass` still require correct filesystem ownership and service-user access.

## Risk and policy

Every action declares one risk tier. The caller cannot lower it.

| Tier | Intended meaning | Examples |
| --- | --- | --- |
| `low` | Read-only or negligible impact | uptime, disk use, service status |
| `medium` | Limited, reversible state change or heavier diagnostic | refresh metadata, start a bounded profile |
| `high` | Production-affecting or user-visible change | restart a service, scale a workload, kill a query |
| `critical` | Broad or difficult-to-reverse change | reboot, terminate an instance, flush data, drain a node |

Account policy decides whether a tier runs, waits for approval, or is denied.
The runner can narrow that decision again with host-local admission allow/deny
patterns and a risk ceiling.

Risk is only useful when the action copy is honest. `side_effects` must name
the actual mutation, interruption, data exposure, and blast radius; the portal
shows that text to the agent, operator, and approver.

## The shell exception

The [`shell` pack](shell/) is a staging-only break-glass tool. Its single action
runs an arbitrary operator-supplied script, bypassing the declared-action model
that the rest of emisar exists to provide.

It is critical-risk, denied by default, and has no detection rule, so it is
never suggested automatically. Do not install or enable it on production
runners.

## Author a pack

Start with the [`showcase` pack](showcase/) or let a coding agent use the public
[`author-pack` skill](../skills/author-pack/SKILL.md).

1. Create `pack.yaml` and one YAML file per action.
2. Keep executable and argv structure fixed; expose only the smallest typed
   argument surface the operation needs.
3. State risk and side effects conservatively.
4. Declare setup requirements and a low-risk verification action.
5. Validate with the same loader the runner uses:

   ```sh
   emisar pack validate ./my-pack
   ```

6. Test representative success, denial, invalid-argument, and missing-tool or
   missing-credential paths before distribution.

Private-registry and publishing workflows are documented at
[emisar.dev/docs/pack-registry](https://emisar.dev/docs/pack-registry) and
[emisar.dev/docs/publishing-packs](https://emisar.dev/docs/publishing-packs).

## Repository maintenance

Catalog contributors must read [`AGENTS.md`](AGENTS.md). A pack change is not
complete until the pack validates, its generated cases and catalog artifacts
are current, the runner/portal contract checks pass, and the public counts above
match the manifests.
