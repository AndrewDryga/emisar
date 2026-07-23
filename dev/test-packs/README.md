# Pack test harness

Every pack has a `test/cases.json` listing one test case per action. It is a
**generated artifact** — `cd tools && go run ./cmd/gencases` derives it from
each pack's `actions/*.yaml` plus the policy tables in
`tools/cmd/gencases/policy.go`; never hand-edit one, change the policy or the
action YAML and regenerate. The harness selects only the backing services
needed by matching packs, invokes `emisar action run` for each case, and
asserts on exit code + stdout substrings. Localhost-only packs share the SUT's
network namespace, matching how the action runs on a real host.

## Layout

```
packs/<pack>/                # at the repo root (a sibling of runner/)
├── pack.yaml
├── actions/*.yaml
└── test/
    └── cases.json          # GENERATED: one entry per action under actions/

dev/test-packs/              # mounted in the container at /workspace/test-packs
├── Dockerfile               # builds emisar-runner-tools (all CLI binaries)
├── docker-compose.yaml      # backing services (postgres, redis, …); mounts packs/ at /packs
├── bin/                     # ignored cross-built runner + Go packtest binaries
├── reports/                 # ignored per-pack logs
└── fixtures/                # seed configs, init SQL, etc.
```

## cases.json schema

```json
{
  "defaults": {
    "env": {"PGHOST": "postgres", "PGPASSWORD": "testpass"}
  },
  "cases": [
    {"action": "postgres.uptime", "args": {}, "expect_exit": 0,
     "expect_stdout_contains": ["start"]},
    {"action": "postgres.kill_pid", "args": {"pid": 99999},
     "expect_exit": [0, 1],
     "skip": "set to non-empty to skip with a note"}
  ]
}
```

- `args`: passed verbatim as `--arg key=value` to `emisar action run`.
- `expect_exit`: scalar or list of accepted exit codes.
- `expect_stdout_contains`: every needle must be present.
- `skip`: non-empty value skips this case (useful for actions that need
  a multi-node fixture we can't easily provide in compose).

## Running

```sh
# Run every generated case. The command owns build, Compose, reports, and cleanup.
dev/run pack test

# Run packs whose name contains a pattern.
dev/run pack test redis
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
