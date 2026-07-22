---
name: development-keycloak-certificates
description: workspace Keycloak certificate generation, macOS browser trust, and automated Chromium trust boundaries
subsystem: agent-stack
sources: [dev/run, dev/keycloak/certs/gen.sh, tools/browser/resolve-chrome.mjs, tools/browser/browser-server.mjs]
updated: 2026-07-22
---

Each workspace generates an ignored CA and Keycloak leaf under
`dev/keycloak/certs/generated/`. The CA lasts ten years, but the server leaf is
limited to 397 days: macOS rejects longer-lived TLS leaves even when their CA is
explicitly trusted. The generated `format` marker renews an old-format leaf
without rotating its CA.

`dev/run certs trust|untrust|status` manages only the generated CA's SHA-256
fingerprint in the macOS user keychain, constrained to SSL for `localhost`.
Parallel workspaces may have the same CA common name; never delete by common
name. Automated Chromium does not depend on host trust and never disables TLS
validation globally: `dev/run` derives the current leaf SPKI, and the browser
launch permits only that exact hash.

Keycloak reads its certificate at process start. `dev/run` fingerprints the
leaf before and after generation and recreates the Coop dependency containers
only when the material changed. Use the command surface for renewal or rotation;
editing or deleting generated files manually can leave a running sidecar serving
stale material.

## Changelog
- 2026-07-22 — created after verifying macOS trust, exact-fingerprint removal, SPKI-only Chromium access, and sidecar recreation
