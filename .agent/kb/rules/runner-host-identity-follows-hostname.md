---
name: runner-host-identity-follows-hostname
description: Default runner identity to the current hostname instead of minting or persisting a parallel generated identifier
subsystem: runner
sources: [runner/connect.go, runner/common.go, runner/connect_test.go]
updated: 2026-07-26
---

# Host identity follows the hostname

## Rule

When `runner.id` is unset, the runner presents the current hostname as its
external identity. An explicit `runner.id` may override that default. Never
mint or persist a separate generated identity for the same host.

## Why

The host lifecycle is the identity boundary. A reboot retains the hostname and
reconnects the same runner. Replacing an ephemeral host gives it a new hostname,
so it enrolls as a new runner without carrying identity state on disk. A second
generated identity obscures that lifecycle and makes replacement behavior
depend on stale local state.

## Good

```go
externalID, err := resolveExternalID(cfg.Runner.ID, hostname)
```

## Bad

```go
externalID := readOrMintUUID(filepath.Join(dataDir, "runner_id"))
```

## Sweep

Search runner code, installer tests, public docs, and operational guidance for
generated UUID identity, `runner_id` identity files, and identity-reset flags or
prompts.

## Enforcement

`TestResolveExternalIDUsesConfiguredIDOrHostname` covers the default, explicit
override, normalization, and missing-hostname failure.
