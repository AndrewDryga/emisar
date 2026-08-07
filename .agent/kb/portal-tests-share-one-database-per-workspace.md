---
name: portal-tests-share-one-database-per-workspace
description: why two concurrent portal test runs in one workspace cancel each other's queries, and how to tell that noise apart from a real missing-synchronization defect
subsystem: agent-stack
sources: [portal/config/test.exs, tools/internal/devtool/portal.go, .github/workflows/ci.yml]
updated: 2026-08-07
---

`portal/config/test.exs` names the test database `emisar_test#{System.get_env("MIX_TEST_PARTITION")}`,
and **nothing sets `MIX_TEST_PARTITION`** — not `./run test`, not the gate, not CI. So every
portal test run in one workspace shares one database and one Ecto sandbox. Separate coop boxes
are safe (each gets its own Postgres container); two runs on the same host workspace are not.

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

The runs still share a database; what changed is that they no longer overlap on it.
`./run gate portal` and `./run test portal` both take one exclusive lock — keyed by the
database `portal/config/test.exs` resolves, so unrelated databases run freely — held across
the migration and the suites. A second run prints `waiting: another portal test run holds
<database>` and starts when the first finishes. Per-run `MIX_TEST_PARTITION` was the other
option and was not taken: it isolates completely but makes every run re-migrate from scratch,
and waiting out one suite is cheaper than that on every single run.

The lock is per user and per database, so it does not help across machines or containers —
CI is unaffected either way, since each job already has its own database.
