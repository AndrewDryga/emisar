---
name: runner-enrollment-key-rotation
description: A changed enrollment key re-registers the configured id or hostname and replaces the cached token
subsystem: runner
sources: [install.sh, runner/internal/cloud/websocket.go, runner/connect.go]
updated: 2026-07-26
---

The runner token records the fingerprint of the enrollment key that minted it.
When the configured key changes, the runner registers again instead of
presenting the cached token (`runner/internal/cloud/websocket.go`).

Registration presents configured `runner.id`, or the current hostname when no
override is set. The installer updates an explicitly supplied changed key in
`runner.env`; it does not mint, persist, or reset a separate runner identity.
On the next connection, the runner replaces the cached token after successful
registration.

An install rollback restores the prior `runner.env` and cached token. Default
uninstall removes the cached token while preserving configuration, durable
dispatch reservations, signing nonces, and the local audit journal. `--purge`
removes all configured data.

## Changelog

- 2026-07-26 - replaced generated UUID identity reset with hostname lifecycle identity.
