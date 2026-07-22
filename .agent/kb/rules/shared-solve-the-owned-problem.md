# Solve the owned problem, not the general one

**Rule.** Scope every mechanism to the inputs and deployments this product
actually has, not to the fully general problem the subsystem could someday
face. Three recurring shapes, all corrected in the 2026-07-20 MCP-wave
simplification:

1. **First-party-authored inputs get an authoring-time lint, not a runtime
   exactness subsystem.** Pack YAML is written by us and reviewed; a value
   class we don't want (fractional `multipleOf`, numeric literals that don't
   survive a float64 round trip) is rejected at pack load / catalog build with
   a clear error — never preserved end-to-end through a parallel exact-decimal
   codec spanning two languages.
2. **Pre-1.0, single-release deployments never get rollout barriers.** No
   capture/exact activation phases, no v1/v2 dual-read formats, no capability
   handshakes guarding a peer version that never shipped, no migration
   compensators for data an older build "might have written" when no such
   build ever ran. Greenfield (creed #6) applies to *rollout machinery* too:
   deploy once, re-review the affected rows, move on.
3. **A new choke point retires the validators it shadows — in the same
   change.** When one boundary becomes authoritative (published input schemas
   validating every MCP call), the per-callsite checks it makes unreachable
   are deleted, not kept "defensively" — dead branches only accumulate drift
   and reviewers.

**Why.** Each shape reads as rigor but is pure carry cost: the exact-number
pipeline (~2,100 lines + a forked dep) protected a number population of zero;
the activation machine put a lock in every dispatch for a flip that never
happened; the shadowed validators grew +541 lines after they became
unreachable. The abuse case is internal: complexity that looks like security
consumes the review budget real boundaries need.

**✅ Good**

```go
// pack load — the value class is unrepresentable, so no downstream code
// ever needs to preserve it
if !floatRoundTrips(lit) {
    return fmt.Errorf("action %s: schema number %s does not survive float64; write the canonical form", id, lit)
}
```

**❌ Bad**

```text
yaml.Node shadow parser → exact json.Number wire → Decimal JSONB sidecar →
forked validator for exact multipleOf → activation phase gating which of two
dialects validates a result
```

**How it's enforced.** Review rule (judgment, not mechanical): for any new
compat layer, staged rollout, or preservation subsystem, name the concrete
deployed artifact that depends on the old behavior. "A future/older version
might" is not an artifact — pre-1.0 there is none, so the mechanism is cut.
Sweep target: `grep -ri "phase\|legacy_\|_v2\|profile"` over a new feature's
diff before commit.
