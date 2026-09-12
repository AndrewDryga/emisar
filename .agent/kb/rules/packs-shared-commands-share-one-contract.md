# Packs shipping the same command share one execution contract

**Rule.** When two packs expose the same underlying command (e.g.
`debugging.pid_io` and `forensics.pid_io` both run `cat /proc/<pid>/io`),
their execution contracts are identical — blocking behavior, timeout,
`cancel_grace`, output caps — and their shared argument uses one identical
validation pattern. Their operator-facing copy matches too: title,
description, argument descriptions, search terms, and examples, because the
catalog text is what an LLM ranks and what an operator reads before
approving. Each twin carries a comment naming the other, so an edit to one
cannot quietly diverge them.

A twin exists because each pack must stand alone — the pack an operator
happens to install must not change what the same command does. That is not a
licence to duplicate a whole capability: when one pack is explicitly the
*deeper* companion of another (systemd-deep says "deeper systemd state than
linux-core"), the shared verbs live in the base pack only. linux-core owns
the systemd unit lifecycle for exactly that reason.

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
# debugging/actions/pid_io.yaml
execution:
  # The execution contract AND the operator-facing copy match forensics.pid_io —
  # same command, deadline, caps, and words, whichever pack the operator
  # installed.
  command:
    binary: cat
    argv: ["/proc/{{ args.pid }}/io"]
  timeout: 5s
```

**❌ Bad**

```yaml
# same command, different kill deadline depending on pack choice
linux-core:   timeout: 60s
systemd-deep: timeout: 120s
# a unit pattern with '-' in the first-char class: flag injection via argv
pattern: "^[A-Za-z0-9@._:-]{1,128}$"
```

**How it's enforced.** `./run check packs` byte-compares every declared twin
pair (`checkPackTwinActions` in `tools/internal/devtool/pack_twins.go`). It
reads the cross-reference comment as the declaration — so a new twin is
enforced the moment its comment is written — resolves the named action by id,
requires the reference to be **mutual**, and then compares the two files line
by line, exempting exactly two lines: the `id:` line and the comment naming
the twin. Everything else, down to where a description wraps, must match.

Write the reference as `match <other-id> —` inside `execution:`, on both sides.
Dropping it on one side is itself a failure, which is what stops a reword from
retiring the check; `TestShippedPackTwinsAreIdentical` additionally pins the
live pairs so rewording both sides at once fails too. To retire a pair on
purpose, remove both comments and that test's entry.

Review alone did not hold this. The 2026-08-28 sweep unified the five systemctl
twins and all 20 unit-name patterns (5 spellings → 1). The 2026-09-11 pass
removed the systemd-deep lifecycle twins and aligned the two `pid_*` pairs'
copy, which had drifted to a bare path (`/proc/PID/io`) on one side and a
sentence on the other — and the line wrapping still diverged until 2026-09-12.
Three passes to converge two pairs is why the compare is mechanical now.
