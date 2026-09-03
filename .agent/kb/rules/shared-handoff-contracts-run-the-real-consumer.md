---
name: shared-handoff-contracts-run-the-real-consumer
description: When one component builds an invocation another component parses, a test feeds the real producer output to the real consumer — a fake that only records argv mirrors the bug
subsystem: shared
sources: [runner/internal/selfupdate/selfupdate_test.go, tools/internal/installtest/runner.go, install.sh]
updated: 2026-09-03
---

# Handoff contracts run the real consumer

## Rule

Where one component builds an invocation that a separately shipped component
parses — the runner's argv for `install.sh`, an installer's call into the
runner CLI, a script's flags for a Go tool — at least one test runs the real
consumer on the real producer output. A fake consumer that records what it was
given can only assert the producer's intent; it turns the producer's test into
a mirror of the bug. Where the consumer is fielded in several versions, the
test also pins every argv shape those versions still send.

## Why

`installerInvocation` passed `--packs ""` and its test asserted exactly that
against a stub whose whole body was a bash shebang. `install.sh`'s
`require_value` rejected an empty value. Both gates were green from runner
0.20.0 through 0.24.0 while every `emisar update` on every host failed with
"flag --packs requires a value".

## Good

```go
args, env := installerInvocation(bundle, tag, receipt, identity)
cmd := exec.Command("/bin/bash", append(args, "--managed-update-contract")...)
```

## Bad

```go
deps.runCommand = func(_ context.Context, name string, args, env []string, _, _ io.Writer) error {
	commandArgs = args // records the argv; nothing ever parses it
	return nil
}
```

## Sweep

Search for test doubles that stand in for a shipped parser (`runCommand`
fakes, `fakeExecutable`, stub `install.sh` bodies) and ask what parses the
recorded input in production.

## Enforcement

`TestReleaseInstallerParsesTheHandoff` and the installer harness check
"managed-update handoff flags" run the real `install.sh` parser on the real
handoff and on the argv fielded runners still send.
