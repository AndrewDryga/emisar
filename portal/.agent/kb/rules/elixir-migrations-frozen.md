# Rule: a committed migration is frozen — never edit it, add a new one

**Rule.** Greenfield ("edit the original, no legacy") is for **code**, not for DB
migrations. A migration is **FROZEN the moment it lands in a commit**. You may
edit a migration file freely *only while it is new and uncommitted in the change
you are making now*; once it is in any commit, **never edit or delete it — write
a NEW migration** that moves the schema forward. "Committed = frozen" is the
whole test: you do **not** have to reason about whether prod has run it.

**Why.** The production release runs `/app/bin/migrate` before boot and each
migration applies **exactly once**. A migration that has run is permanent
history. Editing the file changes nothing in
any database that already ran it — so prod's schema silently diverges from what
the new code expects, and the divergence surfaces as a production outage:

- a fetch path hits a column the migration "added" but prod never got →
  `undefined_column` 500 (the prod-vs-fresh-test-DB `comm` schema-diff method
  exposes the mismatch);
- a removed/renamed `Ecto.Enum` value left in existing rows →
  `ArgumentError cannot load "X"` on every load of that table (one orphan row
  DoSes the read path — see memory: enum-value removal needs a data migration).

A fresh test DB rebuilds from the full migration list, so an edited migration
passes locally and looks fine — the breakage only appears against the
already-migrated prod (and the already-migrated dev) DB. That asymmetry is why
the rule is mechanical, not a judgment call.

**✅ Good** — add a forward migration that alters the committed schema.

```elixir
# priv/repo/migrations/20260707000000_drop_decision_reason.exs  (NEW file)
def change do
  alter table(:approval_decisions) do
    remove :reason, :string
  end
end
```

```elixir
# Swap a unique index in place — the column-derived default name is stable, so
# changeset unique_constraint/3 keeps matching and upserts keep working.
def change do
  drop_if_exists unique_index(:runbooks, [:account_id, :slug])
  create unique_index(:runbooks, [:account_id, :slug],
           where: "deleted_at IS NULL")
end
# Upsert against that partial index must carry the predicate in conflict_target:
#   conflict_target: {:unsafe_fragment, "(account_id, slug) WHERE deleted_at IS NULL"}
```

Removing/renaming an enum value or adding `NOT NULL` is an expand/contract
sequence. First deploy code that stops writing the old value or `NULL` while it
still reads both shapes. Verify every old instance is gone, then backfill or
clean the rows before the schema constraint can reject them. Only a later
release narrows the Ecto read contract. An in-migration cleanup is acceptable
only when a production count proves it is small and bounded:

```elixir
def change do
  # The release check proved this table has only a bounded number of old tokens.
  execute("DELETE FROM user_sessions WHERE auth_method = 'password'", "")
  # ...then the enum/column change
end
```

**❌ Bad** — editing or deleting a migration that is already committed.

```elixir
# priv/repo/migrations/20260616000000_configurable_approval_gate.exs  (in a prior commit)
   create table(:approval_decisions) do
     add :decision, :string, null: false
-    add :reason, :string          # ← deleting this line does NOTHING to prod's schema
     add :decided_at, :utc_datetime_usec, null: false
   end
```

The column still exists in every DB that ran this migration; the schema now says
it shouldn't. Restore the file (`git checkout -- <file>`) and add a new migration.

**Dev-DB gotcha after a legitimate edit-while-uncommitted.** If you add a *new*
table to an uncommitted migration's `up` and a matching `drop table` to `down`,
`mix ecto.rollback` fails on the dev DB that already ran the pre-edit `up` (the
edited `down` drops a table that DB never created). Prefer `mix ecto.reset`
(blocked if a `mix phx.server` holds `emisar_dev` — don't kill the user's
server), or forward-DDL the missing table via `psql` to match `up` exactly.

**Enforced.** The commit-gate hook (`.claude/hooks/commit-gate.sh`, a
PreToolUse(Bash) hook) blocks any `git commit` whose staged tree **modifies,
deletes, or renames** a file under `priv/repo/migrations/*.exs` that exists in a
prior commit (`git diff --cached --diff-filter=MDR`). A brand-new migration is an
add (`A`) and passes. This is a git-diff property, not an AST one, so it lives in
the commit-gate, not Credo. If the gate fires, restore the file and add a new
migration — never `--no-verify` past it.

---

## A migration runs before the app boots — write it to hold no long lock

`/app/bin/migrate` runs to completion **before** an instance starts serving, and
`cd.yml` runs it on every deploy. Anything that takes a write-blocking lock for
the duration is a hard outage, not slow startup, and its length is proportional
to table size — so it passes every review while the table is small and takes the
product down the quarter it isn't.

Today **no migration in this repo uses `concurrently` or
`@disable_ddl_transaction`,** and at least one does an unbatched rewrite of the
largest table (`20260812000000`, `UPDATE action_runs SET args_raw = …` then
`modify :args_raw, null: false`). Those are committed and frozen. The rule is
for the next one.

**Any strong-lock DDL on a populated table** — fail fast if the lock is not
immediately available. Set a transaction-local `lock_timeout` below the maximum
write stall accepted for that rollout. An `ACCESS EXCLUSIVE` request queued
behind an old transaction can make later traffic queue behind it; a failed
migration that can retry is safer than an unbounded traffic stall. The timeout
only bounds lock acquisition, not the work after acquisition, so it never makes
a table scan or rewrite safe by itself.

**Index on a table that already holds production rows** — build it
concurrently, which requires leaving the migration's transaction:

```elixir
@disable_ddl_transaction true
@disable_migration_lock true

def change do
  create index(:action_runs, [:runner_id, :inserted_at], concurrently: true)
end
```

Both attributes are required: `concurrently` cannot run inside a transaction,
and the migration lock holds one open. A concurrent build can leave an
`INVALID` index behind if it fails — that is recoverable (drop it, re-run), a
locked-out fleet is not.

**Backfilling an existing column** — batch by primary key outside the migration
transaction, and put the schema constraint in a *later* migration once the
backfill has drained. A single `UPDATE` over the whole table holds row locks on
every row it touches until commit.

**Adding a CHECK or foreign key to a populated table** — use
`constraint(..., validate: false)` for a CHECK or
`references(..., validate: false)` for a foreign key, commit, then validate it
in a later migration:

```elixir
# First migration: a lock-timeout-bounded ACCESS EXCLUSIVE lock installs the
# constraint; PostgreSQL enforces it for every new or changed row immediately.
def up do
  execute("SET LOCAL lock_timeout = '2s'")

  create constraint(
    :action_run_events,
    :action_run_events_kind_check,
    check: "kind IN ('progress', 'transition', 'error')",
    validate: false
  )
end

def down do
  execute("SET LOCAL lock_timeout = '2s'")
  drop constraint(:action_run_events, :action_run_events_kind_check)
end

# Later migration: the table scan uses SHARE UPDATE EXCLUSIVE, so ordinary
# inserts and updates continue while existing rows are checked.
def change do
  execute(
    "ALTER TABLE action_run_events " <>
      "VALIDATE CONSTRAINT action_run_events_kind_check",
    ""
  )
end
```

Do not add `NOT VALID` and validate it in the same ordinary Ecto migration. The
outer transaction keeps the first command's stronger lock until the validation
and the migration commit, which defeats the split.

**Setting `NOT NULL` on a populated table** — assume a full table scan under the
`ALTER TABLE` lock. Complete the rolling writer change and backfill first, add
`CHECK (column IS NOT NULL) NOT VALID`, validate that check in a later migration,
then set `NOT NULL` in one final short, lock-timeout-bounded migration. PostgreSQL
can skip the `SET NOT NULL` scan when the valid check still exists; do not drop
the proof before that command commits.

**Deleting existing rows** — count the exact predicate in production before
putting a `DELETE` in the deploy path. A large or unknown delete belongs in a
resumable, primary-key-batched cleanup outside the migration transaction. Each
batch bounds row-lock time, WAL volume, replica pressure, and the dead tuples
left for vacuum. The later schema migration should find zero invalid rows and do
only the short schema change.

**Qualifying an unavoidable populated-table scan** — use current production row
counts and relation sizes, replay the exact migration on the production
PostgreSQL major version with at least that much representative data, and keep a
measured writer active throughout. Record both migration duration and maximum
writer stall. A local rehearsal establishes the lock shape and catches an
unbounded operation; its timing is not a production latency guarantee.

**Sweep target.** Any migration touching a table that already has production
rows where the body contains a non-concurrent index build, an immediately
validated CHECK or foreign key, `modify … null: false`, `SET NOT NULL`, or an
unbounded `UPDATE` or `DELETE`. Review the transaction boundary, table size,
lock level, and concurrent-writer evidence before the migration commits.

**Not enforced by a check.** Whether a table is big enough to matter is a
deployment fact, not an AST property, and a blanket "every index is concurrent"
lint would fire on the initial-schema migrations where it is wrong (an empty
table wants the transaction). This is a review rule — check it when you write
the migration, not after prod stalls.
