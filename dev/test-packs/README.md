# Pack behavior harness

Pack contracts and pack behavior are separate checks:

- `./run check packs` validates every manifest and action contract.
- `./run test packs [name-pattern]` runs pack-owned behavior cases against
  disposable Compose systems.

A behavior case must prove something observable. Stable output assertions prove
read actions; state probes prove mutations. Exit code alone and
`stdout_not_empty` are smoke checks, not semantic coverage.

The static check also rejects fixture shapes that CI has already proved unsafe:
unpinned endpoint-address assertions, cumulative cases with no arranged state,
temporary seed-daemon readiness on loopback, too-fast heavyweight probes, and
root identities with no reason. These are authoring errors; Linux still decides
uid ownership, AppArmor, and real startup behavior.

## Ownership and isolation

```text
packs/<pack>/
├── pack.yaml
├── actions/*.yaml
└── test/
    ├── cases.yaml          # cases, assertions, risk accounting, SUT versions
    ├── compose.yaml        # this pack's disposable SUT
    ├── Dockerfile          # optional pack-specific client or SUT image
    └── fixtures/           # optional seeded state and service configuration

dev/test-packs/
├── Dockerfile              # shared action-client image
├── compose.yaml            # shared runner-tools service
├── test-config.yaml        # disposable runner security configuration
├── bin/                    # ignored runner and harness binaries
└── reports/                # ignored aggregate and per-case evidence
```

Every case gets its own Compose project, network, volumes, SUT lifecycle, and
runner-tools container. The devtool builds pack-specific images once, reuses the
shared client image whenever its tag is already present, and skips that image
entirely for a pack that ships its own client. It then runs up to four isolated
cases concurrently. Arrange steps can create the
exact prerequisite state for a case. Terminal actions can stop or destroy their
fixture without affecting any later case.

Cleanup commands are optional hygiene within a case. The outer devtool always
destroys the case project and its volumes, including after failure.

The first service in `cases.yaml` is the primary SUT. Its Compose image must
consume `PACKTEST_VERSION` and `PACKTEST_DIGEST`, either directly or inside the
default for `PACKTEST_IMAGE` when that exact ref can be mirrored. A pack-local
Dockerfile receives the resolved `PACKTEST_IMAGE`; it never reconstructs or
weakens the ref. Each supported version row has an exact digest, and exactly one
row is the default matching Compose. Relevant pull requests run every declared
row for the changed pack; the weekly workflow runs the full compatibility
matrix.

Version rows are support promises, not a release archive. Declare the newest
supported release and the oldest supported family for high-use databases and
orchestrators. Do not enumerate every intermediate patch.

## Plan shape

```yaml
services: [postgres]
versions:
  - version: "18.4"
    digest: "@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    default: true

risk_accountability:
  mode: complete
  exceptions:
    postgres.kill_idle: requires_concurrent_session

secret_env: [PGPASSWORD]
env:
  PGHOST: postgres
  PGUSER: postgres
  PGPASSWORD: packtest-canary-postgres-2a6e1c
  PGDATABASE: testdb

cases:
  - action: postgres.uptime
    expect:
      stdout_contains: [PostgreSQL]

  - action: postgres.vacuum_table
    args: {schema: public, table: orders, analyze: true}
    probes:
      - argv: [psql, -XAt, -c, "SELECT last_vacuum IS NOT NULL FROM pg_stat_user_tables WHERE relname = 'orders'"]
        expect:
          stdout_contains: ["t"]

  - name: postgres.uptime-missing-credentials
    action: postgres.uptime
    unset_env: [PGPASSWORD]
    expect:
      status: failure
      exit: [2]
      reason_contains: [process exited with code 2]
      stderr_contains: [no password supplied]
```

`env` is passed to the runner and its actions only when `test-config.yaml`
allowlists the variable. A case can override values with `env` or remove them
with `unset_env`. Structured action arguments are encoded as JSON.

`arrange`, `probes`, and `cleanup` execute argv arrays without a shell. Use
`[/bin/sh, -c, ...]` only when shell syntax is part of the test. Probes may set
`retry_for` and `retry_every` for eventually consistent state.

When an action target exists only after `arrange`, `resolve_args` captures one
non-empty output line and converts it to the action argument's declared type:

```yaml
resolve_args:
  pid:
    argv: [psql, -XAt, -c, "SELECT pid FROM pg_stat_activity WHERE application_name = 'packtest-victim'"]
    retry_for: 10s
    retry_every: 250ms
```

Keep this for identifiers created by the isolated case. Static inputs belong in
`args`; complex fixture lifecycles do not belong in the harness.

## Risk accountability

When a modeled pack adds or changes a `high` or `critical` action, that action
must have either:

- A successful behavior case, or
- A machine-readable exception in `risk_accountability.exceptions`.

Known exception values are `requires_cluster`, `requires_concurrent_session`,
`requires_dynamic_fixture`, `requires_external_service`, `requires_hardware`,
and `requires_privileged_host`.

`mode: changed` is the default and enforces changed risky actions in selective
CI. `mode: complete` accounts for every risky action in the pack. Exceptions
cannot hide an action that already has a successful case. There is deliberately
no coverage percentage.

## Assertions

Action expectations support:

- `status`: `success` (default) or `failure`
- `exit`: accepted underlying command exit codes; successful actions default to
  `[0]`
- `reason_contains`
- `stdout_not_empty` for smoke only
- `stdout_contains` / `stdout_not_contains`
- `stderr_contains` / `stderr_not_contains`
- `json`: stdlib JSON Pointer assertions

Actions declaring `output.parser: json` are always required to emit valid JSON.
Pointers address objects and arrays without jq or JSONPath:

```yaml
expect:
  json:
    /status: healthy
    /items/0/name: fixture
```

`secret_env` names credential-bearing plan variables. Each must contain a
unique `packtest-canary-*` token, including credentials embedded in a URL. The
harness rejects a canary found in action stdout, stderr, reason, error,
parser error, or the runner event journal. Missing credentials, unavailable
services, invalid arguments, and missing targets should be represented as
named failure cases where the pack can model them honestly.

## Execution identity

Runner-tools executes as UID/GID `65532:65532` by default, including when a
pack supplies a custom client image. A case that genuinely needs superuser
access declares both fields:

```yaml
runner_user: root
runner_reason: Postfix reserves daemon-control commands for the superuser.
```

Use a second non-root failure case when it usefully proves the permission
boundary. Privileged SUT containers, capabilities, shared PID namespaces, and
root runner identity remain explicit in the pack-owned Compose plan or case.

## Reports

The harness writes:

```text
dev/test-packs/reports/<invocation>/<pack>.log
dev/test-packs/reports/<invocation>/<pack>/<case>.log
```

Each command prints its invocation-specific report directory. That same
invocation identity isolates its Compose projects, so separate commands may
exercise the same pack and case concurrently without sharing containers,
volumes, networks, or report files. The shared client image is the deliberate
exception: it is tagged by the bytes of its Dockerfile, so every run and every
checkout reuses one build and changed content lands on a new tag.

Each case report records the pack and SUT versions, image digest, execution
identity, resolved images, action result, and durations. Failures also capture
Compose health, container inspect data, SUT logs, and cleanup errors. CI uploads
the complete reports directory for a failed matrix row.

## Running

```sh
./run test packs postgres
./run test packs postgres --case postgres.uptime
./run test packs postgres --hostile
./run test packs

# A declared alternate version resolves its committed digest.
PACKTEST_VERSION=17.6 ./run test packs postgres

# An ad hoc version must provide an exact digest.
PACKTEST_VERSION=17.6 \
  PACKTEST_DIGEST=@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  ./run test packs postgres
```

`--hostile` writes a case-local Compose override that limits each SUT service to
one CPU, 1536 MiB of memory, and 512 PIDs. CI uses it to make startup races and
expensive readiness probes visible on every behavior row. It does not emulate
Linux ownership or AppArmor on Docker Desktop, so a local pass remains feedback,
not the verdict for those boundaries.

## CI SUT mirrors

The matrix copies its five slowest immutable SUT refs to the public, dev-only
`ghcr.io/andrewdryga/emisar-packtest-suts` package. `mirrors.yaml` selects the
repositories; each pack's `cases.yaml` still owns the version and digest. Print
the exact source, target tag, and digest-locked mirror refs with:

```sh
./run pack mirrors --registry ghcr.io/andrewdryga/emisar-packtest-suts
```

Only the main/scheduled mirror workflow can write the package. Behavior jobs
use a mirror only when its pack, version, and digest all match the generated
map. They verify all five mirrors anonymously before widening from eight to
twelve rows; bootstrap or a registry outage falls back to the source refs and
the last known-safe width of eight.
