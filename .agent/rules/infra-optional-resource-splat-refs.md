# infra: consumers of optional resources use splat, never a hard index

**Rule.** When resource B references a count-gated resource A, and B can exist while A does not (B's count condition is broader than A's, or B is unconditional), the reference must degrade with A's absence — `A[*].attr` (splat, yielding `[]`) or an expression guarded by A's own condition — never `A[0].attr`.

**Why.** A hard `[0]` bakes "A always exists whenever B does" into the graph. The first lifecycle change that lets A reach count 0 independently (parking a VM, downscoping an environment) then fails at plan time or forces reference surgery across files — turning a one-variable flip into a refactor. Splat keeps absence a first-class state the graph already handles.

✅ Good — the LB graph outlives the parked instance; membership degrades to empty:

```hcl
resource "google_compute_instance_group" "livebook" {
  count     = var.livebook_enabled ? 1 : 0
  instances = google_compute_instance.livebook[*].self_link
}
```

❌ Bad — plan explodes the moment the instance's count can be 0 while the group's is 1:

```hcl
resource "google_compute_instance_group" "livebook" {
  count     = var.livebook_enabled ? 1 : 0
  instances = [google_compute_instance.livebook[0].self_link]
}
```

Same-lifecycle references are fine and idiomatic: `A[0]` where the consumer's count condition is identical to A's, or strictly implies it (e.g. the instance gated on `enabled && running` reading the data disk gated on `enabled`) — absence can never diverge there.

**Sweep target.** `grep -nE '\[0\]\.' infra/*.tf`, then for each hit compare the consumer's count condition with the target's; fix any consumer that can outlive its target. Swept 2026-07-17: the instance-group membership was the only divergent-lifecycle hit.

**How it's enforced.** Judgment plus the plan itself — no CI source grep (AGENTS.md creed #8 bans placement-rule greps). Exercising the park/enable dials in a plan is the mechanical check: a violation fails immediately at plan time.
