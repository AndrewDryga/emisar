---
name: development-keycloak-certificates
description: workspace Keycloak certificate generation, macOS browser trust, and automated Chromium trust boundaries
subsystem: agent-stack
sources: [run, tools/internal/devtool/certs.go, tools/internal/browser/manager.go]
updated: 2026-07-22
---

Each workspace generates an ignored CA and Keycloak leaf under
`dev/keycloak/certs/generated/`. The CA lasts ten years, but the server leaf is
limited to 397 days: macOS rejects longer-lived TLS leaves even when their CA is
explicitly trusted. The generated `format` marker renews an old-format leaf
without rotating its CA.

`./run certs trust|untrust|status` manages only the generated CA's SHA-256
fingerprint in the macOS user keychain, constrained to SSL for `localhost`.
Parallel workspaces may have the same CA common name, so fingerprint selection
distinguishes the active workspace. Automated Chromium does not depend on host
trust: `./run` derives the current leaf SPKI, and the browser launch permits
only that exact hash while normal TLS validation remains active.

Coop boxes receive decoys at private-key paths. `./run doctor` therefore checks
the public CA, hostname, validity window, and leaf signature inside a box, while
the host additionally proves that both stored private keys match their public
certificates. Box diagnostics operate without access to signing material.

Keycloak reads its certificate at process start. The Go tooling fingerprints the
leaf before and after generation and recreates the Coop dependency containers
only when the material changed. The command surface coordinates renewal or
rotation with sidecar recreation; direct generated-file changes can leave a
running sidecar serving stale material.

Related rule: [development TLS trust stays workspace-scoped](rules/shared-development-tls-trust-stays-workspace-scoped.md).

## Changelog
- 2026-08-04 — split public-chain validation from host-only private-key
  validation so secret-shadowed Coop boxes can run the complete doctor safely
- 2026-07-22 — created after verifying macOS trust, exact-fingerprint removal, SPKI-only Chromium access, and sidecar recreation
