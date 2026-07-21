---
name: runner-enrollment-key-reset
description: A changed enrollment key rotates the token while preserving external identity unless the installer explicitly resets generated auth state
subsystem: runner
sources: [install.sh, runner/internal/cloud/websocket.go, runner/connect.go]
updated: 2026-07-20
---

The runner treats enrollment-key rotation and identity reset as separate choices.
Its token file carries a fingerprint of the enrollment key that minted it; a new
key makes the runner register again instead of reusing that token
(`runner/internal/cloud/websocket.go:155-189`). The generated external identity
still comes from `<data_dir>/runner_id`, so preserving that file reconnects the
same logical runner while deleting it creates a new UUID
(`runner/connect.go:325-343`).

`install.sh` therefore updates an explicitly supplied changed key but preserves
identity by default. Interactive installs offer a generated-identity reset;
unattended installs require `--reset-identity` (`install.sh:233-276`). Reset and
uninstall remove token files before `runner_id`, and a failed upgrade restores
the prior key, token, and identity before restarting the old service
(`install.sh:674-719`). Configuration-pinned `runner.id` and a custom
`cloud.token_path` remain operator-owned paths and need manual cleanup.

## Changelog
- 2026-07-20 — created from the enrollment-key update and uninstall reset flow.
