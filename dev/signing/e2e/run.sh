#!/usr/bin/env bash
#
# Host-side signed-dispatch end-to-end check. Brings up the enforcing runner
# (runner-signed) + its key-minting init (signing-init) under the `test` profile,
# waits for the runner to connect, then drives the REAL MCP bridge to prove a
# signed dispatch runs and an unsigned one is refused. Stdlib Go only (tools/cmd/signing-e2e).
#
#   docker compose up -d            # the base stack (db, portal, seeder, runners)
#   ./dev/signing/e2e/run.sh
#
# The signing material is generated at stack-up by `signing-init` into a docker
# volume — no CA or leaf private key is committed. `docker compose down -v`
# rotates it. The driver reaches the portal over the published localhost:4010 and
# the bridge over the in-network portal:4000 (so signing happens in the bridge,
# exactly as on a real client).
set -euo pipefail
cd "$(dirname "$0")/../../.." # repo root, so `docker compose` finds the stack

# The portal, runner, and bridge share the signed-envelope contract. Rebuild all
# three so a running development stack cannot make this cross-component check
# pass or fail against stale code.
echo "[signed-dispatch-e2e] building current portal + runner + mcp images (cached if unchanged)..."
docker compose --profile test build portal runner-signed mcp

echo "[signed-dispatch-e2e] bringing up portal + signing-init + runner-signed (profile: test)..."
docker compose --profile test up -d portal
docker compose --profile test up -d --force-recreate signing-init runner-signed

PORTAL_URL="${PORTAL_URL:-http://localhost:4010}" \
  MCP_KEY="${MCP_KEY:-emk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA}" \
  exec go run ./tools/cmd/signing-e2e
