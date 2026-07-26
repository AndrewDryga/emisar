# Pack fixtures assume an isolated, non-root SUT

**Rule.** Every behavior case runs in its own disposable Compose project, as a
non-root runner identity, on a network the bridge addresses fresh. A fixture may
therefore assume nothing that outlives its own case and nothing it did not set
up itself. Three shapes to recognize:

1. **Never assert a value the environment assigns.** A container's IP, a
   generated hostname, a port the daemon picked. If a case genuinely needs to
   name an address, *pin it* in `compose.yaml` (an explicit listen address, a
   fixed subnet) so the assertion describes the answer rather than the lease.
2. **State the case needs, the case arranges.** Counters, activity tables, and
   caches start empty because the server started seconds ago — and an image that
   seeds through `docker-entrypoint-initdb.d` seeds a *temporary* daemon that is
   shut down before the real one starts, so those writes are invisible to
   anything measuring the running server. Add an `arrange:` step that creates the
   state the assertion reads.
3. **A command that needs root says so.** Many real operator commands are
   superuser-reserved (`postfix check`) or write root-owned paths (`nginx -t`
   opens the pid file and creates its cache temp dirs). Either declare
   `runner_user: root` with a `runner_reason`, or widen exactly the paths the
   fixture owns — never both, and never by making the whole SUT privileged.

**Why.** The isolation hardening was the point: a case that shares a server with
its neighbours proves nothing about the action, and a root runner hides every
permission bug an operator will hit. But a workstation cannot see the difference
— **Docker Desktop runs a VM that masks host/container uid ownership and loads
no AppArmor profile**, so a fixture depending on root-owned paths or on
`ip netns` passes locally and fails on an Ubuntu runner. Six fixtures broke this
way at once and each looked like a product defect until read closely; none was.
Treat "passes on my Mac" as no evidence at all for this class.

**✅ Good**

```yaml
# compose.yaml — the address the assertion names is pinned, not leased
environment:
  CASSANDRA_LISTEN_ADDRESS: 127.0.0.1
```

```yaml
# cases.yaml — the case creates the activity it then asserts on
- action: mongo.top
  arrange:
    - argv: [/bin/sh, -c, mongosh "$MONGO_URI" --quiet --eval 'db.getSiblingDB("packtest").orders.find().toArray()']
  expect:
    stdout_contains: ['"totals"', packtest.orders]
```

```yaml
# cases.yaml — a superuser-reserved command declares why
- action: postfix.check_config
  runner_user: root
  runner_reason: Postfix reserves the postfix command itself for the superuser.
```

**❌ Bad**

```yaml
# asserts whatever the bridge handed out today
- action: cassandra.nodetool_getendpoints
  expect:
    stdout_contains: [127.0.0.1]

# asserts state a previous case used to leave behind
- action: mongo.top
  expect:
    stdout_contains: [packtest.orders]
```

**How it's enforced.** CI, and only CI — the pack behavior matrix on Linux is
the authority for this class, so push the fix and read the job rather than
trusting a local pass. `packtest` already refuses a case with no semantic
assertion, so weakening an assertion to `stdout_not_empty` is not an escape
hatch: fix the environment instead. Sweep signal: an IP address, hostname, or
port literal inside `expect:` that the fixture does not set; an action whose
name implies cumulative counters (`top`, `*_stats`, profilers) with no
`arrange:`; and a case whose command is documented as superuser-only but
declares no `runner_user`.
