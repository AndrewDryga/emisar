# Risk tiers follow real-life impact, with a floor for raw-content readers

**Rule.** An action's `risk` tier states what the action does to the real
system and what its output exposes — judged per action, per product. Two
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

The ceiling from [[packs-redaction-completeness-follows-a-closed-key-space]]
still holds: a generic log reader stays at `medium` — going higher takes a
written per-action decision in the action's own description (e.g.
`airflow.task_log`'s approval note, `linux.cron_recent`'s inline-credential
note). Such a written decision always wins over both the floor and any sweep.

**Why.** The tier drives policy defaults — what auto-runs and what waits for
an operator. A class-swept tier is wrong in both directions at once: it
under-gates the database restart and over-gates the exporter. And a `low`
raw-log read hands an LLM (and the audit trail) whatever the application
printed, which is exactly the content the operator never enumerated.

**✅ Good**

```yaml
# kubernetes/pod_logs — raw stdout of an arbitrary app
risk: medium
# kubernetes/events_recent — typed k8s events, structured messages
risk: low
# ec2.start_instance high, databricks.warehouse_start medium — different
# real-life blast radius, same verb: correct.
```

**❌ Bad**

```yaml
# linux.tail_log at low: raw file content rated as if it were a status read
risk: low
# a sweep: "every *_start action becomes high" — erases per-product judgment
```

**How it's enforced.** Review against this rule; no mechanical check —
"returns raw log content" is a judgment about output semantics that YAML
inspection cannot make reliably. The 2026-08-28 sweep re-tiered 40 readers
and left the deliberate exceptions in place.
