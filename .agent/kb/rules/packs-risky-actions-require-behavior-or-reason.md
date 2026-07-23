# Rule: risky modeled actions require evidence or a typed reason

**Rule.** In a pack with a container-backed behavior model, every new or
changed `high` or `critical` action has either a successful semantic behavior
case or a machine-readable `risk_accountability.exceptions` reason. Packs
graduated to `mode: complete` account for every risky action. Never replace
this with a global coverage percentage.

Every behavior case owns a fresh Compose project and SUT lifecycle. Setup is
case-local, ordinary cases are not restarted within the case, and terminal
actions may destroy their fixture. Runner-tools is non-root by default; a root
case carries a concrete `runner_reason`. Test credentials use unique
`packtest-canary-*` values declared through `secret_env`.

**Why.** Percentages reward easy reads and weak output checks while leaving the
most destructive actions untested. Shared fixtures make terminal tests
order-dependent. Root-only harnesses hide permission assumptions. Generic test
passwords cannot prove that credentials stay out of action results and audit
events.

**Good.**

```yaml
risk_accountability:
  mode: complete
  exceptions:
    redis.cluster_failover: requires_cluster

secret_env: [REDISCLI_AUTH]
env:
  REDISCLI_AUTH: packtest-canary-redis-c08d17

cases:
  - action: redis.shutdown_nosave
    probes:
      - argv: [/bin/sh, -c, "redis-cli PING >/dev/null 2>&1 || echo stopped"]
        expect:
          stdout_contains: [stopped]
```

**Bad.** Claiming a pack is covered because 80 percent of actions merely
returned output; running stop, drain, or shutdown after unrelated reads in one
shared service; marking an untested risky action skipped with prose; or running
every action as root because the client image happened to default to root.

**Sweep.** For each modeled pack, compare `risk: high|critical` action IDs with
successful cases and exception keys. Search plans for `stdout_not_empty` as the
only assertion, generic passwords or tokens, root runner identity without a
reason, and multiple cases sharing one Compose project.

**Enforced.** `./run check packs` validates plans. Selective CI rejects a
changed risky action without a successful case or known exception.
`./run test packs` gives every case a unique Compose project, defaults the
runner to UID/GID 65532, scans declared canaries, and retains per-case failure
evidence.
