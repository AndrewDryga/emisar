# Pack test harness

Every pack has a `test/cases.json` listing one test case per action. It is a
**generated artifact** — `cd tools && go run ./cmd/gencases` derives it from
each pack's `actions/*.yaml` plus the policy tables in
`tools/cmd/gencases/policy.go`; never hand-edit one, change the policy or the
action YAML and regenerate. The harness boots the backing services the
actions need, invokes `emisar action run` for each case, and asserts on exit
code + stdout substrings.

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
├── harness.sh               # run a single pack's cases
├── run-all.sh               # run every pack with a cases.json
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
# 1. Build the emisar runner binary into ./bin (git-ignored, mounted read-only at
#    /opt/emisar/bin). It must be a LINUX binary matching the container's arch —
#    `go env GOARCH` gives the host arch, which is also the default image platform.
( cd runner && GOOS=linux GOARCH="$(go env GOARCH)" go build -o ../dev/test-packs/bin/emisar . )

# Build the runner-tools image (one-time)
docker compose -f dev/test-packs/docker-compose.yaml build runner-tools

# Run every pack (boots all SUTs)
docker compose -f dev/test-packs/docker-compose.yaml up -d
docker compose -f dev/test-packs/docker-compose.yaml run --rm runner-tools \
    /workspace/test-packs/run-all.sh

# Run one pack
docker compose -f dev/test-packs/docker-compose.yaml up -d redis
docker compose -f dev/test-packs/docker-compose.yaml run --rm runner-tools \
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
