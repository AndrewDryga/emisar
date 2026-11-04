# Rule: a read bounds its work on the target, not only on the client

**Rule.** An action that makes a server or runtime do work sets its limits where
that work runs. The runner enforces an action's `timeout` by killing the local
client, and that does not stop the work on the other end. Set a statement limit
just under the action's `timeout` and a short lock wait, in the action's own
program, and let the failure say what happened.

**Why.** A killed client looks finished, and the work it started keeps going with
nobody watching, so a retry adds more:

- Four `postgres.largest_tables_full` timeouts during a held lock left four backends
  holding connection slots until the lock cleared. PostgreSQL does not notice a dead
  client while it waits, because `client_connection_check_interval` defaults to 0.
- MySQL 8.4 and 9.7 behave the same on a metadata lock, and `lock_wait_timeout`
  defaults to a year. MariaDB 11.8 noticed the dead client.
- `bin/app rpc` evaluates through `:erpc`, which does not cancel remote work. A
  `:supervisor.which_children` on a stuck supervisor stayed on the node for good, one
  stuck process per retry, from a `low` read.

This matters most during an incident: that is when reads time out, when an agent
retries them, and when the target has the least to spare.

**Good.**

```yaml
# The limits end with the transaction, so they are safe behind PgBouncer's
# transaction pooling, and the first statement is not printed under -q.
- "-XAtq"
- "-c"
- "SET LOCAL statement_timeout = '28s'; SET LOCAL lock_timeout = '5s'; SELECT ..."
```

```yaml
# The version comments keep one statement valid on both servers.
- "SET SESSION lock_wait_timeout=5 /*!50708 , max_execution_time=13000 */ /*M!100108 , max_statement_time=13 */; SELECT ..."
```

On a BEAM node, run the read in a worker the node itself kills at a deadline
(`rpc` in `packs/elixir-beam/scripts/release_ctl.sh`).

**Bad.**

```yaml
- "-XAt"
- "-c"
- "SELECT ... pg_total_relation_size(relid) ..."   # only the client has a limit
```

```yaml
env:
  # A startup parameter, so what sits in front of the server decides what happens to
  # it. PgBouncer refuses an unknown one by default, up to 1.24 for
  # default_transaction_read_only too. Before 1.26, one set to ignore the options
  # parameter drops it in silence: postgres.explain_analyze promised read-only this
  # way, and a query it ran deleted rows. A limit or a guarantee an action depends on
  # lives in its own program.
  PGOPTIONS: "-c statement_timeout=28s"
```

**Not every action.** A maintenance statement that runs for hours by design keeps
its long `timeout` and no statement limit, and `VACUUM` and `REINDEX CONCURRENTLY`
refuse to run in the transaction a limit is set in. A call that holds no lock on
application data has nothing to bound. These are listed with their reasons in
`packDBBoundExemptActions`.

**Sweep.** `cockroach`, `mongodb`, and `clickhouse` run clients of their own and have
not been checked: for each, establish first whether a killed client really leaves
work behind, as MariaDB shows it may not.

**Enforced.** `validatePackDBReadBounds` in `tools/internal/devtool/pack_db_bounds.go`,
run by `./run check packs`, for `psql` and `mysql`, and it refuses `PGOPTIONS` in any
action. Behavior cases in `postgres` and `mysql` prove a read behind a held lock fails
fast and leaves nothing waiting, and `postgres` runs reads through PgBouncer that
refuses and that drops startup options.
