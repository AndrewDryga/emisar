# Packs shipping the same command share one execution contract

**Rule.** When two packs expose the same underlying command (e.g.
`linux.systemctl_restart` and `systemd.unit_restart` both run
`systemctl restart <unit>`), their execution contracts are identical —
blocking behavior, timeout, `cancel_grace`, output caps — and their shared
argument uses one identical validation pattern. Each twin carries a one-line
comment naming the other, so an edit to one cannot quietly diverge them.

The canonical systemd unit-name pattern is
`^[a-zA-Z0-9@:_.][a-zA-Z0-9@:_.\-]{0,127}$` (optional-arg variant wraps it in
`(...)?`). The first-character class deliberately excludes `-`: unit names
ride argv after flags like `-u`, so a dash-leading value would reach the tool
as an option, not a name.

**Why.** The pack an operator happens to install must not change what the
same command does to their host: before this rule, `systemctl restart` had a
60s deadline from one pack and 120s with a 30s cancel grace from the other,
and `journalctl`'s pattern accepted `--no-hostname` as a "unit". Divergent
twins also mean one pack's rejection teaches the model an argument shape the
other pack then accepts.

**✅ Good**

```yaml
# linux-core/actions/systemctl_restart.yaml
# The execution contract matches systemd.unit_restart — same command, same
# deadline, whichever pack the operator installed.
execution:
  timeout: 120s
  cancel_grace: 30s
```

**❌ Bad**

```yaml
# same command, different kill deadline depending on pack choice
linux-core:   timeout: 60s
systemd-deep: timeout: 120s
# a unit pattern with '-' in the first-char class: flag injection via argv
pattern: "^[A-Za-z0-9@._:-]{1,128}$"
```

**How it's enforced.** Review plus the paired cross-reference comments; the
2026-08-28 sweep unified the five systemctl twins and all 20 unit-name
patterns (5 spellings → 1).
