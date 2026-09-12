# Rule: a target argument is gated by the risk tier, not by policy or admission

**Rule.** A pack argument that names a deployment-specific target — a systemd
unit, a service, a database, a host, a container — is bounded by an anchored
`pattern`, never by a hardcoded `enum` of one fleet's names. What decides
whether that target may be touched is the action's **risk tier**, because
nothing below the pack filters by argument value. Tier such an action for the
worst target its pattern admits, and say in the `description` what the argument
reaches. Never write, in a pack comment or an author guide, that operator
policy or runner admission decides *which* target may be acted on.

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

So a `high`-tier `service_restart` with a pattern-bounded `unit` is gated —
policy sends it to approval, and the approver sees the resolved unit in the
run's arguments card and, when our published pack is provably byte-for-byte
the runner's, in the command preview. The same action tiered `low` restarts
whatever the pattern admits with no human in the loop, on every account running
the shipped default. Believing in a per-target filter is how an action gets
tiered one step low.

**Good.**

```yaml
# The pattern keeps the argument injection-safe; the risk tier decides
# whether a human approves the run before a unit is touched.
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

Equally bad is the reaction that overcorrects back into an `enum` of
`{cassandra,nginx,postgresql,docker}`: that list is wrong for the next fleet
and can't touch `nomad`/`consul`/`frr`/whatever this operator actually runs.
The over-narrow `systemctl_restart` unit enum was removed for exactly that
reason (b7664f3f). Reserve `enum`/`allowed` for environment-INDEPENDENT value
sets — a log level, `stream: stdout|stderr`, an output format.

**Sweep.** Any pack comment, manual bullet, or docs paragraph telling an author
that policy or admission narrows a *target value*; and any mutating action with
a pattern-bounded target argument whose tier assumes something below the pack
will restrict it.

**Enforced.** Review only. The loader checks that a bound exists, not what the
author believes gates the value.
