---
name: elixir-performance
description: Find and fix performance problems in portal/ — N+1 queries, missing preloads, unbounded lists/assigns, missing DB indexes, slow context reads. Use when a page or list is slow, the DB is hot, LiveView sockets are heavy, or before shipping a list/heavy read path.
effort: medium
argument-hint: "[context, LiveView, or query to profile]"
allowed-tools: Read, Grep, Glob, Bash
---

# Performance pass

Measure, then fix the cause. Don't micro-optimize what isn't hot. The big wins in a
Phoenix/Ecto app are almost always **N+1 queries, unbounded result sets, and missing
indexes** — in that order.

## The usual suspects (emisar-specific)

1. **N+1 queries.** An association loaded per-row in a loop. Symptom: the same
   `SELECT` repeated in the log.
   - Fix: declare the association in the Query module's `preloads/0` and pass
     `:preload` to `Repo.fetch/list` (IL-10) — never `Repo.preload` inside an
     `Enum.map`. Detect: `rg -n 'Repo\.preload|\.\w+\b' ...` for context calls or
     preloads inside `Enum.`/comprehensions.
2. **Unbounded lists.** Loading every row, or assigning a big list to the socket.
   - Lists that can grow (runs, audit events, runners): page with `Repo.list/3`
     (keyset via `cursor_fields`), and render with **`stream/3`** in LiveView, never
     `assign(socket, :items, all)` (IL-18).
3. **Missing indexes.** Every `Query.by_*` filter, every FK, and the `not_deleted`
   soft-delete predicate should be backed by an index. Cross-check the Query helpers
   against the migration; a partial index `where deleted_at is null` matches
   `not_deleted/1`.
4. **Slow query / wrong plan.** Confirm with `Repo.explain(:all, query)` in
   `iex -S mix` (verify the call exists/shape first) — look for `Seq Scan` on a
   large table where an index should apply.
5. **Over-preloading.** The opposite problem: loading associations a screen doesn't
   use. Preload only what the caller renders.

## How to run it

```sh
cd portal
# repeated identical SELECTs in dev = N+1 (queries log by default in dev)
# profile a specific read in iex:
echo 'Emisar.Repo.explain(:all, Emisar.Runs.ActionRun.Query.not_deleted())' | iex -S mix
```
Read the LiveView's `mount`/`handle_*` for list assigns; read the context read path
for preload shape; read the migration for indexes.

## Output

Findings ordered by impact: `issue · where · cost · fix`. Fix the unambiguous ones
(add a preload to `preloads/0`, switch an assign to a stream, add a missing index in
a NEW migration — IL-11: a committed migration is frozen, never edit it). Leave a judgment call (is
this list big enough to page?) as a flagged question, not a silent change. Re-measure
after fixing.
