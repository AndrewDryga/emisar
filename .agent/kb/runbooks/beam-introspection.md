# Inspecting a running portal node

Use this when a production portal node is slow, leaking memory, or wedged, and
the metrics say *something* is wrong without saying what. Everything here is
read-only and safe on a live node; none of it stops traffic.

The release ships two libraries for exactly this — `recon` and `observer_cli` —
and until now nothing wrote down that they were there. A tool nobody has
recorded is a tool nobody reaches for at 3am, which is the only time it matters.

## Getting a shell on the node

`bin/emisar remote` attaches an IEx session to the running release. Reach the
instance first through IAP (`./run ops portal ...`); the release is at `/app`.

```
/app/bin/emisar remote
```

This is a real shell on a serving node. Prefer the counting and sampling calls
below over anything that walks every process, and never leave `:observer_cli`
running unattended — it polls.

## What to run

**Memory climbing, cause unknown.** Which process types hold the most memory:

```elixir
:recon.proc_count(:memory, 10)
```

**Binary memory climbing.** Refc binaries held by long-lived processes are the
classic BEAM leak; this forces a garbage collect on the worst offenders and
reports what it recovered:

```elixir
:recon.bin_leak(10)
```

**A queue backing up.** The processes with the longest mailboxes — usually the
fastest way to find the one consumer that has fallen behind:

```elixir
:recon.proc_count(:message_queue_len, 10)
```

**Live overview.** A top-style dashboard, useful while reproducing something:

```elixir
:observer_cli.start()
```

Quit it with `q`. It samples continuously, so do not leave it attached.

## What this does not cover

Fleet-wide questions — how many runners are connected, which accounts are
affected — belong in the console and in the `emisar.*` metrics, not here. This
runbook is for the single node in front of you.

For clustering failures specifically (`cluster discovery failed`, nodes not
finding each other), start from `EMISAR_CLUSTER_PROJECT` and the GCE tag rather
than the BEAM: the alert text in `infra/monitoring_application.tf` names the
checks in order.
