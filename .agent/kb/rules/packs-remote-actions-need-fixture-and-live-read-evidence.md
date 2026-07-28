# Rule: remote actions need fixture and live read evidence

**Rule.** Every action in a new remote-provider pack has a successful semantic
behavior case through the real packaged script or client. Before claiming that
the pack works against the provider, run at least one representative read-only
action per provider API family through Emisar on a governed target. Exercise
deeper resource-specific reads when the target already has those resources.

Never create, update, restart, resize, reset, delete, or destroy infrastructure
to arrange a live smoke. When no compatible runner or resource exists, record
that exact limitation and report the provider smoke as blocked. Deterministic
fixture success is useful evidence, but it is not live-provider evidence.

**Why.** Schema and catalog validation prove that a descriptor loads. A local
fixture proves argv, parsing, bounds, error handling, and secret projection.
Only a provider request catches real CLI/API drift, permissions, service
enablement, resource-shape variation, and credential delivery. Conflating
these layers creates false confidence in a pack that has never reached its
target.

**Good.**

```text
gcp-dns: 6/6 fixture cases green; gcp.dns_zones also succeeded through Emisar
on an existing project. No DNS records were created or changed.
```

```text
gcp-networking: gcp.interconnect_diagnostics fixture case green; live smoke
blocked because the governed project has no attachment. Do not create one for
testing.
```

**Bad.** Calling a catalog gate a provider test; using an ungoverned local
cloud credential after Emisar discovery found no runner; creating a temporary
database, bucket, DNS record, certificate, load balancer, or VM merely to make
a diagnostic read return data; or omitting empty-resource and permission
results from the evidence.

**Sweep.** For each new remote pack, compare every action ID with its behavior
cases. Then group actions by provider API family and inspect the task log for a
governed live read, an existing-resource deeper read, or a precise blocker.
Search operator-facing summaries for fixture results described as live tests.

**Enforced.** `./run test packs <name>` and the Linux behavior matrix judge the
deterministic model. Live read evidence remains a review requirement because
CI must not hold production cloud credentials or arrange customer resources.
