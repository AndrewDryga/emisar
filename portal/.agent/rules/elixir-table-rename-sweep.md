# A table rename sweeps five surfaces, or authorization silently breaks

**Rule.** Renaming a DB table (a NEW migration — committed ones stay frozen) must update, in the SAME change:

1. **Every constraint + index on the table** — `ALTER TABLE <new> RENAME CONSTRAINT` / `ALTER INDEX ... RENAME TO` to the new-table prefix. Postgres does not rename them on table rename, but Ecto *infers* `unique_constraint`/`foreign_key_constraint` names from the table name — a violation then RAISES instead of returning `{:error, changeset}`.
2. **The schema module's `schema "<table>"` string.**
3. **Every explicit `name:` option** in changesets referencing the old-prefix constraint names.
4. **Every `for_subject/2` clause matching `Auth.Authorizer.query_source/1`** — it returns the table name **as an atom** (`:memberships`). A stale clause doesn't raise once the old atom exists elsewhere (binding names, Multi step names, assign keys keep it alive): it falls through to the `_ -> queryable` catch-all and **IL-4 row scoping silently stops** — a cross-account leak.
5. **Raw SQL strings** — `Ecto.Adapters.SQL.query!` helpers in tests, `fragment(...)` — the table name hides inside a longer string, so grep the **bare word**, not the quoted token.

**Why.** #1 and #4 fail in the worst way: #1 turns a domain error into a 500; #4 removes an authorization gate with no error at all. Both shipped-class bugs were caught only by the full-suite gate during the 2026-07-16 rename pass.

**✅ Good** — the five sweeps, verified by: dev-DB migrate (rename path on data), fresh scratch replay, rollback + re-migrate, the full test suite (its unique-violation tests prove #1; its denial/cross-account tests prove #4), and a raw-SQL negative probe per new backstop.

**❌ Bad** — `rename table(:memberships), to: table(:account_memberships)` alone; or sweeping strings but not atoms (`grep '"memberships"'` misses `:memberships ->` and `"UPDATE user_tokens SET ..."`).

**Enforced by:** review + this checklist; `query_source/1`'s `String.to_existing_atom` raises loudly ONLY while the new atom is unreferenced — never rely on it.

**Named bindings stay.** `as: :memberships`, cursor_fields atoms, and Multi step names are arbitrary atoms, not table references — renaming them is churn with no behavior change; leave them as domain nouns.
