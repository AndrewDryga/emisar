# Pack test harness

Every pack has a `test/cases.yaml` listing one test case per action. The
harness boots the backing services that the actions need, invokes
`emisar action run` for each case, and asserts on exit code + stdout
substrings.

## Layout

```
runner/
├── examples/packs/<pack>/
│   ├── pack.yaml
│   ├── actions/*.yaml
│   └── test/
│       └── cases.yaml      # one entry per action under actions/
└── test-packs/
    ├── Dockerfile           # builds emisar-runner-tools (all CLI binaries)
    ├── docker-compose.yaml  # backing services (postgres, redis, …)
    ├── harness.sh           # run a single pack's cases
    ├── run-all.sh           # run every pack with a cases.yaml
    └── fixtures/            # seed configs, init SQL, etc.
```

## cases.yaml schema

```yaml
defaults:
  env:
    PGHOST: postgres
    PGPASSWORD: testpass

cases:
  - action: postgres.uptime
    args: {}
    expect_exit: 0
    expect_stdout_contains: ["start"]
  - action: postgres.kill_pid
    args: { pid: 99999 }
    expect_exit: [0, 1]      # accept either — pid may not exist
    skip: ""                  # set to non-empty to skip with a note
```

- `args`: passed verbatim as `--arg key=value` to `emisar action run`.
- `expect_exit`: scalar or list of accepted exit codes.
- `expect_stdout_contains`: every needle must be present.
- `skip`: non-empty value skips this case (useful for actions that need
  a multi-node fixture we can't easily provide in compose).

## Running

```sh
# Build the runner-tools image (one-time)
docker compose -f test-packs/docker-compose.yaml build runner-tools

# Run every pack (boots all SUTs)
docker compose -f test-packs/docker-compose.yaml up -d
docker compose -f test-packs/docker-compose.yaml run --rm runner-tools \
    /workspace/test-packs/run-all.sh

# Run one pack
docker compose -f test-packs/docker-compose.yaml up -d redis
docker compose -f test-packs/docker-compose.yaml run --rm runner-tools \
    /workspace/test-packs/harness.sh redis
```

## Skip rationale

Some actions can't be tested without specific multi-node fixtures
(e.g. `consul.raft_remove_peer` needs a real dead peer, `clickhouse.system_drop_replica`
needs a dead replica with leftover metadata). Those cases set `skip:`
with a one-line reason. They still count as coverage when reading the
catalog — they're marked, not forgotten.

Cloud packs (`aws-*`, `cloudflare`) require credentials or LocalStack.
The compose file includes LocalStack for AWS smoke tests; cloudflare and
`github-cli` mutator cases are skipped unless `CF_API_TOKEN` /
`GH_TOKEN` are set.
