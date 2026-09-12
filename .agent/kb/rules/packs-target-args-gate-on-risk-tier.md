# Rule: a target argument is gated by the risk tier, not by a per-target filter

**Rule.** A pack argument that names a deployment-specific target — a systemd
unit, a service, a database, a host, a container — is bounded by an anchored
`pattern`, never by a hardcoded `enum` of one fleet's names. The account's
policy decides whether the run proceeds, waits for a human, or is denied, and
the only things it has to decide on are the action id and the action's **risk
tier** — nothing below the pack filters by argument value. So the tier is the
whole signal the author controls: tier such an action for the worst target its
pattern admits, and say in the `description` what the argument reaches. Never
write, in a pack comment or an author guide, that operator policy or runner
admission decides *which* target may be acted on.

**Why.** Neither layer sees the argument.

- Account policy keys off the risk tier and the action id only:
  `rules.defaults` maps a tier to `allow` / `require_approval` / `deny`, an
  entry in `rules.overrides` is `{"action": "<id glob>", "decision": …}`, and
  `rules.approval` carries `min_approvals` + `allow_self_approval`. The
  validated section list is exactly `schema_version`, `defaults`, `overrides`,
  `approval` (`portal/apps/emisar/lib/emisar/policies/policy/changeset.ex`).
  There is no place to put a value.
- Runner admission has two axes, action-id shell globs and a risk ceiling:
  `Admit(actionID string)` never receives the arguments
  (`runner/internal/admission/admission.go`). It hides a whole action from a
  host; it cannot hide one unit from an admitted action.

**Which decision a tier produces is the operator's, not the tier's.**
`Policies.evaluate_with_policy/3` first resolves the policy that applies to the
dispatch — the runner's own, else its group's, else the account's — and
`evaluate/2` then takes the first `overrides` glob that matches the action id
and only otherwise falls back to that policy's `defaults[tier]`
(`portal/apps/emisar/lib/emisar/policies.ex`). Our shipped default
(`@default_rules`) allows `low` and `medium`, requires approval for `high`, and
denies `critical`, with no overrides. So on a default account a `high`-tier
`service_restart` with a pattern-bounded `unit` waits for an approver, who sees
the resolved unit in the run's arguments card and, when our published pack is
provably byte-for-byte the runner's, in the command preview. An account that
allows `high`, or writes an override for that action id, gets a different
answer for the same tier — write "under the shipped default", never "`high`
means approval". The same action tiered `low` restarts whatever the pattern
admits with no human in the loop on that default. Believing in a per-target
filter is how an action gets tiered one step low.

**Good.**

```yaml
# The pattern keeps the argument injection-safe; the risk tier is the only
# thing the operator's policy gates this run on, so tier for the worst unit.
risk: high
args:
  - name: unit
    validation:
      pattern: "^[a-zA-Z0-9@:_.][a-zA-Z0-9@:_.\\-]{0,127}$"
```

**Bad.**

```yaml
# Operator policy and admission decide WHICH unit may be targeted.  <- false
risk: medium
```

And the overcorrection away from it, which is just as wrong:

```yaml
# `high`, so a human approves before this unit is touched.  <- false: true
# only under the shipped default. This account may allow `high`, or carry an
# override on the action id that decides before any tier default is read.
risk: high
```

Equally bad is the reaction that overcorrects back into an `enum` of
`{cassandra,nginx,postgresql,docker}`: that list is wrong for the next fleet
and can't touch `nomad`/`consul`/`frr`/whatever this operator actually runs.
The over-narrow `systemctl_restart` unit enum was removed for exactly that
reason (b7664f3f). Reserve `enum`/`allowed` for environment-INDEPENDENT value
sets — a log level, `stream: stdout|stderr`, an output format.

**Sweep.** Any pack comment, manual bullet, or docs paragraph telling an author
that policy or admission narrows a *target value*; any mutating action with a
pattern-bounded target argument whose tier assumes something below the pack
will restrict it; and the overcorrection in the other direction — prose saying
a tier by itself decides, approves, or gates a run, with no "under the shipped
default" scoping the claim to `@default_rules`.

**Enforced.** Review only. The loader checks that a bound exists, not what the
author believes gates the value.
