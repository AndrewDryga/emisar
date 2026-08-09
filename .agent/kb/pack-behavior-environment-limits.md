---
name: pack-behavior-environment-limits
description: what each risk_accountability exception reason means, which environment would actually close it, and why two of the six are harness gaps rather than environment limits
subsystem: packs
sources: [tools/internal/packtest/packtest.go, packs/*/test/cases.yaml]
updated: 2026-08-08
---

A risky action that no behavior case covers is declared as an exception in its
pack's `test/cases.yaml`, against a closed reason vocabulary the harness
validates (`tools/internal/packtest/packtest.go:850`). The exceptions ARE the
inventory of what the container harness cannot reach — read the current one from
the tree rather than from a list here:

    grep -rn "requires_" packs/*/test/cases.yaml

What each reason costs to close, largest first (counts as of 2026-08-08):

- **`requires_privileged_host` — 82 actions, 22 packs.** Systemd as PID 1,
  package installs, sysctl, kernel modules, block devices, another process's
  `/proc`. The reusable unit is an OS family, not a pack: one Debian-family and
  one RPM-family disposable root environment would cover all 22. A few of them
  (`docker`, `podman`, `beam`, `jvm`, `pm2`) may only need a privileged
  container rather than a VM — worth checking before building anything heavier.
- **`requires_cluster` — 35 actions, 8 packs.** A second live node of the same
  service, for rebalance, decommission, and peer-removal verbs. Not a new kind
  of environment: it is the existing Compose harness with a multi-node topology
  and a join step.
- **`requires_external_service` — 11 actions, 6 packs.** A real vendor endpoint
  (Cloudflare, GitHub). Official sandboxes, one per vendor.
- **`requires_dynamic_fixture` — 5 actions, 3 packs.** NOT an environment limit.
  `arrange` creates the fixture and `resolve_args` feeds its server-generated id
  into the action, both of which the harness already has; `consul.destroy_session`
  was declared this way and now runs as an ordinary case. The remaining five
  (`mongo.drop_index`, `kafka` ×3, `nomad.job_dispatch`) are the same shape.
- **`requires_concurrent_session` — 4 actions, 4 packs.** Also not an environment
  limit: killing a query, mutation, connection, or operation needs a second
  connection held open while the action runs, which a Compose sidecar in the
  plan's `services` can hold.
- **`requires_hardware` — 3 actions, 1 pack.** Only `ipmi`. A BMC simulator that
  speaks the real protocol (`ipmi_sim`, VirtualBMC) is the reusable option; a
  fake binary that returns success would prove nothing.

Two consequences worth carrying: an exception written before the harness grew
`arrange`/`resolve_args`/`probes` can be stale, so re-check the reason before
treating it as a limit; and 58% of the inventory sits behind one environment
capability, so an OS-family root environment is the only build that changes the
coverage picture materially.

## Changelog
- 2026-08-08 — created; counts derived from `packs/*/test/cases.yaml`, reason
  vocabulary verified against `packtest.go`, and the `requires_dynamic_fixture`
  claim verified by closing `consul.destroy_session` as a passing case
