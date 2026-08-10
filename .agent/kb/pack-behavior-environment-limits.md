---
name: pack-behavior-environment-limits
description: what each risk_accountability exception reason means, which environment would actually close it, and why two of the six are harness gaps rather than environment limits
subsystem: packs
sources: [tools/internal/packtest/packtest.go, packs/docker/test/cases.yaml]
updated: 2026-08-09
---

A risky action that no behavior case covers is declared as an exception in its
pack's `test/cases.yaml`, against a closed reason vocabulary the harness
validates (`tools/internal/packtest/packtest.go:850`). The exceptions ARE the
inventory of what the container harness cannot reach — read the current one from
the tree rather than from a list here:

    grep -rn "requires_" packs/*/test/cases.yaml

What each reason costs to close, largest first (counts as of 2026-08-10):

- **`requires_privileged_host` — 48 actions, 16 packs.** Systemd as PID 1,
  package installs, sysctl, kernel modules, block devices, another process's
  `/proc`. **Measured 2026-08-08: all but nine of the original 82
  are reachable from a privileged disposable CONTAINER, not a VM.** systemd runs as PID 1 under
  `--privileged --cgroupns=host` with `/sys/fs/cgroup` rw, and `systemctl
  start/restart/enable/mask`, `journalctl --vacuum-time`, `apt-get
  install/remove`, `sysctl -w`, `/proc/sys/vm/drop_caches`, `iptables -I` and
  `strace -p` all work inside it. The docker and podman exceptions are a
  category error rather than a limit — a `docker:dind` sibling in the case's own
  Compose project is not the host's socket, and `docker.inspect` passes against
  one once `DOCKER_HOST` is added to `inherit_env` in
  `dev/test-packs/test-config.yaml` — all nine docker exceptions are now real
  cases on that pattern. The systemd half is built too: `systemd-deep`,
  `linux-core` and `debian` run against a service manager booted as PID 1 in
  their own privileged container, which the runner drives by joining that
  container's PID namespace and `/run` (see any of their `test/compose.yaml`).
  Two more shapes cover the rest of what is done: a capability granted on its
  own where that is all an action needs — `cap_add: [NET_ADMIN]` for `firewall`,
  `[SYS_PTRACE]` for `process-forensics` — and no SUT at all where the action
  mutates the machine it runs on, as `debian`'s apt cases do. What genuinely does not work is a kernel
  module the host lacks (`zfs`, and `wireguard`/`nfsd` on a workstation), kernel
  state a container SHARES with its host (`drop_caches`, `sysctl_set`, the clock
  verbs — covering those would mutate the CI machine), and pfSense, which is
  FreeBSD. Nothing in this bucket is closed by a virtual machine — the
  capability that matters is a privileged container. Each pack's own
  `test/cases.yaml` states which of these applies to it.
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
treating it as a limit; and the same goes for the reason TEXT — most of the
`requires_privileged_host` rationales assert an impossibility that measurement
disproved. What is actually being traded is whether we accept privileged
disposable containers in CI, which is safe on a per-job hosted VM and not on a
self-hosted runner.

## Changelog
- 2026-08-10 — firewall and process-forensics covered by capability rather than
  privilege, taking the bucket to 48 across 16 packs
- 2026-08-10 — systemd lane built: systemd-deep, linux-core and debian covered,
  taking the privileged-host bucket to 54 across 18 packs. Three traps live in
  those images — one shared machine-id, volatile journal storage, and the client
  user in `systemd-journal` — each of which otherwise reads as an empty journal
- 2026-08-09 — docker's nine exceptions closed against a `docker:dind` sibling,
  and every remaining privileged-host rationale rewritten to what is actually
  true; the bucket is 73 across 20 packs
- 2026-08-08 — measured the privileged-host bucket: systemd as PID 1 and a dind
  sibling both work in containers here, so 73 of the 82 need no VM; recorded the
  kernel-module and FreeBSD residue that does
- 2026-08-08 — created; counts derived from `packs/*/test/cases.yaml`, reason
  vocabulary verified against `packtest.go`, and the `requires_dynamic_fixture`
  claim verified by closing `consul.destroy_session` as a passing case
