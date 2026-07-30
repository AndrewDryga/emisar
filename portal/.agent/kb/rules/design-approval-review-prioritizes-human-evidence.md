# Approval review prioritizes human evidence

## Rule

An approval or high-consequence confirmation shows the decision evidence in
the operator's vocabulary:

1. what action or operation will run;
2. its risk;
3. the human runner or target name;
4. every visible argument and value.

Those facts are visible without opening a disclosure. Machine provenance such
as content digests, compound runner references, row IDs, and execution UUIDs
stays persisted and available through audit or canonical detail, but it does
not occupy the primary decision scan.

Approval copy states the prompt boundary explicitly. When one approval covers a
whole frozen operation, say that no later approval prompt will occur. Describe
policy, access, trust, or availability rechecks as conditions that can stop
dispatch, not as gates that may ask the operator again.

## Why

An operator can judge a path, port, service, or timeout. They cannot infer the
meaning of an opaque digest or UUID under time pressure. Hiding arguments while
showing provenance reverses the decision hierarchy and encourages approval
without review. Ambiguous recheck copy also makes a one-time approval sound like
the first step in a sequence of prompts.

## Good

- `caddy.reload_config · high`, `on edge-fra-01`, followed by
  `file /etc/caddy/Caddyfile`.
- “Approve once to release every action shown here. This execution will not ask
  for another approval.”
- A later dispatch-time policy denial is described as stopping the execution.

## Bad

- A runner name followed by `~<digest>` and an exact pack hash while arguments
  are collapsed.
- UUID-only execution history.
- “Each action still passes approval checks,” which implies more prompts.

## Enforced

LiveView tests assert that frozen visible arguments and human runner names are
rendered, machine hashes are absent from approval/runbook decision surfaces,
and whole-run approval copy explicitly rules out another prompt. Screenshot
review covers the pending approval and execution detail.

Sweep approval, confirmation, preflight, and execution-summary surfaces for
hashes/UUIDs in primary rows, hidden visible arguments, and copy that leaves the
number of approval prompts ambiguous.
