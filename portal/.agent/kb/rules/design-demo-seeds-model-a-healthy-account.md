# Demo seeds model one healthy, believable account — not a test rig

## Rule

The demo account's seed data exists so default console captures show a real,
healthy, lived-in account. Every seeded fact a page renders gets a believable
value, and nothing is seeded merely to exercise a mechanism:

- **No volume filler.** Pagination, cursors, and filter behavior are proven by
  tests, not by seeding 90 members, 86 runners, or a 36-item approvals backlog.
  Filler drowns the curated story and reads as the fixture it is.
- **No duplicate identities.** One person does not own a pile of near-identical
  keys ("Claude Code - payments", "Claude Code - checkout", …). Each seeded
  credential earns its row with a distinct story (a second owner, a never-used
  OAuth connect, a dormant drift, one mid-swap rotation).
- **Versions derive from `Emisar.Compat`** (`runner_target()`, `mcp_target()`),
  never pinned literals — a pinned version starts earning the "outdated" nudge,
  and eventually the rose "unsupported" chip plus a fleet-wide upgrade banner,
  the day the target moves.
- **Timestamps are backdated to where the fact sits in the account's story.**
  A roster stamped at seed time reads "joined 1m ago" on every row; a run row
  inserted at seed time floats to the top of the list even when its
  `finished_at` says 4h ago (lists order by insertion). Backdate `inserted_at`
  (and whatever the surface renders) so the timeline reads lived-in.
- **A seeded integration presents itself as working.** Directory state pushed
  through the real SCIM entry points also stamps the provider's
  `scim_last_seen_at`; otherwise the connection card shows an amber
  "never synced" beside four synced users — a fixture reporting itself broken.
- **Seeded mutations leave the receipts a live path would.** A terminal run gets
  its audit event; a dispatched approval carries its context snapshot. A demo of
  a security product must not model missing audit rows.
- **Deliberate teaching states survive on purpose** — one offline host with a
  reason ("drained for kernel upgrade"), one pending approval, one mid-swap
  rotation. One quiet amber per surface is a story; a rose leading the page is a
  broken account.

## Why

The founder's exact reports: "agents.webp leads with a rose", "team-page's rail
still shows 2FA enrolled: 0 of 90", "we don't need to show dupes of 10 different
identities for one person", "cleanup seeds from all extra entities, they were
there to test paging, and it works". Screenshots are marketing surfaces; the
account behind them must look like a real customer's healthy account.

## ✅ Good

```elixir
runner_version: Emisar.Compat.runner_target()
# roster orders newest-joined first — stagger believable joins
{jordan.id, days_ago.(35)}, {priya.id, days_ago.(28)}, …
# a seeded run lands where its execution sits in the timeline
|> Ecto.Changeset.change(inserted_at: succeeded_at, queued_at: succeeded_at)
```

## ❌ Bad

```elixir
# 6 groups × 7 regions × 2 ordinals = 84 filler runners "so lists paginate"
for group <- groups, region <- regions, ordinal <- ~w[01 02], do: …
mcp_bridge_stale = "0.2.7"   # earns the rose "unsupported" chip by design
runner_version: "0.4.2"      # rots below the compat minimum as targets move
```

## How it's enforced

Review judgment at the seed diff plus looking at every affected capture
(`./run capture docs <shot>`) before shipping it. Reseeding a shape change needs
a FRESH database (`docker compose --profile test down -v && ./run smoke`) — the
seed converges by inserting what is missing, so deleted filler code does not
delete previously seeded filler rows. Never re-run the seeder against a live
stack: its runbook-history preflight takes over connected runners' leases and
the append-only audit keeps the churn.
