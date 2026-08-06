# infra: transient scarcity is not bought off with standing spend

**Rule.** When an occasional shortage stalls an operation — a zonal stockout during a rollout, a burst that briefly clears a quota, a cold start — fix it with a mechanism that costs nothing (placement flexibility, retry, an operator unstick someone can run in one command) or accept the delay. Never provision capacity that idles between the rare events it exists for: an extra reserved slot, a warm spare, a tier held for a spike. Provisioned capacity is sized to what serves continuously, never to the worst minute of a deploy.

**Why.** Idle capacity bills every hour of the month for an event that lasts minutes, and it buys less than it looks like: the next shortage that lands somewhere the padding doesn't cover stalls in exactly the same way. A stall an operator clears with one command is cheaper than a line item that never stops.

✅ Good — the reservation covers the fleet that is always serving, a rollout surge takes ordinary on-demand capacity, and a stockout delays the deploy without removing a serving VM:

```hcl
zone_reservation_counts = {
  for index, zone in var.zones : zone => (
    floor(var.instance_count / length(var.zones)) +
    (index < var.instance_count % length(var.zones) ? 1 : 0)
  )
}
```

❌ Bad — a slot reserved in every zone so the surge never waits, idle every hour no rollout is running:

```hcl
zone_reservation_counts = {
  for index, zone in var.zones : zone => (
    floor(var.instance_count / length(var.zones)) +
    (index < var.instance_count % length(var.zones) ? 1 : 0) +
    1 # rollout surge
  )
}
```

**Sweep target.** Every resource carrying a size, count, tier, or minimum, and for each one name what uses that capacity continuously; whatever is left over is a standing bill for an occasional event. Swept 2026-08-06: `google_compute_reservation` is the only in-repo resource that could be sized for a peak, and it tracks the steady-state fleet. The sizing inputs themselves (`machine_type`, `instance_count`, `db_tier`) are Terraform Cloud workspace values — apply the same test when one of them moves.

**How it's enforced.** Judgment at review; no source check distinguishes a justified size from a padded one. A diff that raises a count, tier, or minimum has to say what uses the increase continuously — "so a rollout never waits" is a rejection, and the answer is the free mechanism or the accepted delay.
