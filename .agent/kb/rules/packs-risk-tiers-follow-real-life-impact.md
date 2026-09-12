# Risk tiers follow real-life impact, with floors for raw content and inbound exposure

**Rule.** An action's `risk` tier states what the action does to the real
system and what its output exposes — judged per action, per product. Three
consequences:

1. **Never re-tier by verb class.** Actions sharing a verb ("start",
   "restart", "delete") legitimately span tiers: starting a database or
   something that can take a VM down is not the same real-life event as
   starting a prometheus exporter, even though both "resume metered billing".
   A sweep that equalizes a verb class erases the per-product judgment the
   tier exists to carry. (Founder decision, 2026-08-28, rejecting exactly such
   a sweep.)
2. **Raw log/app content floors at `medium`.** An action whose output is
   arbitrary operator/app free text — file tails and greps, journalctl lines,
   container/task stdout, CI logs, stored-log queries, serial-console output,
   error-event payloads — is at least `medium`, because that content
   routinely carries PII, tokens, and request data no redaction list can
   enumerate. Vendor-structured status, typed event streams, aggregates, and
   metadata (counts, names, positions, sizes) may stay `low`. The same
   real-life read gets the same tier regardless of which binary performs it.
3. **Inbound exposure and link saturation floor at `medium`.** `low` promises
   no *inbound* exposure and no heavy blast radius — not merely no host
   mutation. An action that starts a server, opens a listener, or binds a port
   is at least `medium` even when it is transient and touches no files:
   opening the host to inbound connections *is* the state change. So is a probe
   that generates sustained, link-saturating traffic — real congestion on a
   shared path — as against a cheap `ping` or `curl`. Reserve `low` for reads
   and cheap, bounded probes. Sweep signal: a `low` action that starts a
   server, passes `--listen`/`-s`, binds a port, or floods a link. In
   `iperf3`, `server` is `medium` for the inbound port, and `client` and `udp`
   for the saturating traffic.

The ceiling from [[packs-redaction-completeness-follows-a-closed-key-space]]
still holds: a generic log reader stays at `medium` — going higher takes a
written per-action decision in the action's own description (e.g.
`airflow.task_log`'s approval note, `linux.cron_recent`'s inline-credential
note). Such a written decision always wins over both the floor and any sweep.

**Why.** The tier drives policy defaults — what auto-runs and what waits for
an operator. A class-swept tier is wrong in both directions at once: it
under-gates the database restart and over-gates the exporter. And a `low`
raw-log read hands an LLM (and the audit trail) whatever the application
printed, which is exactly the content the operator never enumerated. A `low`
listener is the same failure on the write side: the shipped default auto-runs
it, so the host takes inbound connections — or a shared link congests — with
no human in the loop, on a tier that promised a look rather than a change.

**✅ Good**

```yaml
# kubernetes/pod_logs — raw stdout of an arbitrary app
risk: medium
# kubernetes/events_recent — typed k8s events, structured messages
risk: low
# iperf3/server — a one-shot inbound listener, no files touched
risk: medium
# ec2.start_instance high, databricks.warehouse_start medium — different
# real-life blast radius, same verb: correct.
```

**❌ Bad**

```yaml
# linux.tail_log at low: raw file content rated as if it were a status read
risk: low
# iperf3.client at low: a link-saturating probe rated like `ping`
risk: low
# a sweep: "every *_start action becomes high" — erases per-product judgment
```

## Three families judged once (2026-09-11)

These came out of a catalog-wide comparison that found the same operation
tiered two ways. Each is decided here so the next pack copies a decision
rather than a neighbour.

**Reload a daemon's config — `high`.** Twelve of thirteen reload actions
already said so; `f2b.reload` said `medium` and moved up. A reload applies
whatever is on disk RIGHT NOW, so the change is not bounded by the action's
arguments the way `medium` requires: a reloaded nginx changes routing, a
reloaded bind changes what the world resolves, a reloaded fail2ban changes
who is banned. The operator approving it is approving a file they did not
pass. Four reloads stay `medium` deliberately, because none of them puts an
unpassed file into effect for work the service is already doing:
`systemd.daemon_reload` re-indexes unit files and leaves every running unit on
its old definition until a restart action gates the change,
`cassandra.nodetool_reloadlocalschema` rebuilds in-memory schema from the
node's own system tables and reads no config file at all,
`cassandra.nodetool_reloadseeds` replaces a seed list that only governs which
peers are contacted later while current gossip continues unchanged, and
`cassandra.nodetool_reloadssl` swaps keystore material for new connections
only and fails on unreadable material before it can break them. That is the
line for the next reload action, and it is narrower than "does it reach live
behavior": `high` when the reload hands an unpassed file the work the service
is already doing — routing, resolution, who is banned — because nothing in the
action's arguments bounds what that file says. The four above stay `medium` on
the specific ground each one states, not on a general claim about live traffic:
the new definition waits for a separate gated action, no file is read at all,
the change only governs which peers are contacted later, or — `reloadssl` — the
swap is one kind of material, validated before it can take effect, leaving
established sessions on their current session. New connections *are* live
service behavior; that is why the short version of this line is wrong. A reload
matching none of those four grounds is `high`.

**Cancel one running query — `high`.** `postgres.cancel_query` said so;
`cockroach.cancel_query` said `medium` and moved up. Both cancel exactly one
statement and leave the connection open, so the argument for `medium` is
real — but the two are the same real-life event on the same wire protocol,
and a tier that depends on which engine answers is the drift this rule
exists to stop. Up, not down: the unsafe direction removes a gate.

**Start a workload — it depends, and that is correct.**
`ec2.start_instance` and `gcp-compute.instance_start` are `high`; they bring
up a billable machine with its own inbound surface. `nomad.job_start`,
`rmq.start_app` and `databricks.cluster_start` are `medium`; they schedule
work inside a cluster that is already running and already exposed. Same verb,
different real-life event — which is rule 1, not a violation of it.

**How it's enforced.** Review against this rule; no mechanical check —
"returns raw log content" is a judgment about output semantics that YAML
inspection cannot make reliably, and so is "opens a listener", which lives in
an argv template or a packaged script rather than in a field. The 2026-08-28
sweep re-tiered 40 readers and left the deliberate exceptions in place.
