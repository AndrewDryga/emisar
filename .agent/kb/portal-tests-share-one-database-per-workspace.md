---
name: portal-tests-share-one-database-per-workspace
description: how Portal test database partitions and locks prevent concurrent migrations from cancelling another suite's queries
subsystem: agent-stack
sources: [portal/config/test.exs, tools/internal/devtool/portal.go, .github/workflows/ci.yml]
updated: 2026-09-10
---

`portal/config/test.exs` names the test database `emisar_test#{System.get_env("MIX_TEST_PARTITION")}`,
so the command that chooses the partition also chooses the database and its lock. Focused
`./run test portal ...` commands use the default `emisar_test` database. The complete Portal
gate uses two persistent databases: `emisar_test_emisar` for the domain app and
`emisar_test_emisar_web` for the web app. It compiles the umbrella once, then prepares and runs
those app suites in parallel. Each suite gets one quarter of Mix's default process-level
ExUnit case budget, so their combined test concurrency stays bounded at the CPU available to the command.

The collision has one mechanism, and it is not the sandbox:

1. `ensurePortalTestDatabase` runs `ecto.create` (idempotent) then **`ecto.migrate`**. When a
   run has pending migrations, that phase issues DDL — `ALTER TABLE`, a non-concurrent
   `CREATE INDEX` — which takes `ACCESS EXCLUSIVE` on the table.
2. The other run's queries block on that lock. They are not deadlocked; they are waiting.
3. DBConnection's default 15s query timeout fires and **cancels the statement**, which is why
   the message reads `canceling statement due to user request` rather than a timeout — the
   cancel is a `pg_cancel_backend`, and the "user" is our own pool.

The resulting output is the whole observed signature:

```
** (Postgrex.Error) ERROR 57014 (query_canceled) canceling statement due to user request
** (DBConnection.ConnectionError) client #PID<N> ({SomeTest, :"test …"}) exited
** (DBConnection.OwnershipError) cannot find ownership process for #PID<N>
Postgrex.Protocol … disconnected: (DBConnection.ConnectionError) client #PID<N> exited
```

Proven directly rather than inferred: holding the exact lock a migration takes —
`BEGIN; LOCK TABLE accounts IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(60);` against the
workspace Postgres — while running one web LiveView file reproduced all four lines. The
control matters as much: two concurrent suites with **no** migrate phase peaked at 59 of 97
connections and produced zero disconnect lines, so pool exhaustion is not the cause and
raising `pool_size` fixes nothing.

**Telling it apart from a real defect.** The test-output guard exists to catch a test whose
process exits with a query still in flight, and that defect looks different:

| | shared-database collision | missing synchronization point |
|---|---|---|
| which tests fail | arbitrary, different every run | the same test, repeatedly |
| where it lands | as often in `setup` as in an assertion | in or after the action under test |
| alone | always clean | still reproduces, given enough runs |
| the other run's log | shows a `database migrations` phase | irrelevant |

An arbitrary failing set that includes setup-time cancels points at a second portal run
migrating, not at a sync point in the tests it named. One test that keeps reappearing is the
real thing, and `AGENTS.md` §7 already covers it: flush the LiveView after asserting its
broadcast, so queued `handle_info` work finishes while the sandbox owner is still alive.

Every command takes an exclusive lock keyed by the database that `portal/config/test.exs`
resolves and holds it across migration and tests. A second command for that database prints
`waiting: another portal test run holds <database>` and starts when the first finishes.
Unrelated partitions continue immediately. Stable gate partitions avoid both failure modes:
the app suites use different databases, and repeat gates reuse already-migrated
databases instead of creating a new one every time. Focused commands keep the default database
because making every short run migrate a fresh partition costs more than waiting for another
focused run.

The lock is per user and per database, so it does not help across machines or containers —
CI is unaffected either way, since each job already has its own database.

## Changelog
- 2026-09-10 — the complete gate moved its two app suites onto stable isolated partitions and
  runs them concurrently after one shared compile; focused commands retain the default database.
