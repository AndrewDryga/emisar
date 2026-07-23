# Pack behavior harness

Pack validation and pack behavior are separate gates:

- `./run check packs` validates every manifest and action contract.
- `./run test packs [name-pattern]` runs the selected pack-owned behavior
  plans against disposable Compose services.

Behavior plans are handwritten. A case is coverage only when it proves an
observable result: a stable output assertion, or a state probe after the
action. Exit code alone is rejected. Mutating cases must probe the changed
state and clean it up.

Packs without a faithful container model have no plan yet. Their action
contracts are still validated, but they are reported as contract-only rather
than hidden behind permanent skips. Host, kernel, hardware, and vendor
environments will be added separately when they can model the real target.

## Layout

```text
packs/<pack>/
├── pack.yaml
├── actions/*.yaml
└── test/
    └── cases.yaml          # pack-owned behavior plan

dev/test-packs/
├── Dockerfile              # shared action-client image
├── docker-compose.yaml     # disposable systems under test
├── fixtures/               # service configuration and seeded state
├── bin/                    # ignored runner and harness binaries
└── reports/                # ignored per-pack logs
```

Each plan declares its own Compose dependencies. The harness starts only the
union needed by the selected plans.

## Plan schema

```yaml
services: [postgres]
env:
  PGHOST: postgres
  PGUSER: postgres
  PGPASSWORD: testpass
  PGDATABASE: testdb
cases:
  - action: postgres.uptime
    args: {}
    expect:
      exit: [0]
      stdout_contains: [PostgreSQL]

  - action: example.mutate
    args:
      name: fixture
    expect:
      stdout_not_empty: true
    probes:
      - name: fixture changed
        argv: [examplectl, get, fixture]
        expect:
          stdout_contains: [changed]
        retry_for: 10s
        retry_every: 1s
    cleanup:
      - name: restore fixture
        argv: [examplectl, reset, fixture]
```

`services` must name services in `docker-compose.yaml`. `env` is passed to the
runner, but an action can inherit a variable only when `test-config.yaml`
allowlists it. Structured argument values are encoded as JSON.

`arrange`, `probes`, and `cleanup` execute argv arrays without a shell. Use an
explicit `[/bin/sh, -c, ...]` only when shell syntax is part of the test.
Cleanup always runs, including after an action or probe failure.

Expectations support:

- `exit`: accepted exit codes; defaults to `[0]`
- `stdout_not_empty`
- `stdout_contains`
- `stderr_contains`

Unknown fields, duplicate actions, nonexistent action IDs, exit-only cases,
semantic-free probes, and mutation cases without probes and cleanup fail
before execution.

## Running

```sh
./run test packs postgres
./run test packs
```

The command builds the runner and harness, starts the selected disposable
services, writes `reports/<pack>.log`, and removes the Compose project and
volumes when it finishes.
