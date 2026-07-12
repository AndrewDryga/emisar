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

# The runner + bridge images must carry the CA signing CLI / EMISAR_SIGNING_CERT
# support; rebuild them from current source (cached + fast when unchanged) so a
# stack whose images predate the CA cutover still runs the e2e.
echo "[signed-dispatch-e2e] building current runner + mcp images (cached if unchanged)..."
docker compose --profile test build runner-signed mcp

echo "[signed-dispatch-e2e] bringing up signing-init + runner-signed (profile: test)..."
docker compose --profile test up -d signing-init runner-signed

# The on-call demo key must be able to see the enforcing runner's group. The seed
# grants this on a fresh stack (seeds.exs); this idempotent UPDATE also covers a
# stack whose portal image predates that seed change, so the e2e stays robust.
docker compose exec -T db psql -U postgres emisar_dev -c \
  "UPDATE api_keys SET runner_group_filter = array_append(runner_group_filter, 'signed-iad') WHERE name = 'Claude Code - on-call' AND NOT ('signed-iad' = ANY(runner_group_filter));" >/dev/null

PORTAL_URL="${PORTAL_URL:-http://localhost:4010}" \
  MCP_KEY="${MCP_KEY:-emk-mcp-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD}" \
  exec go run ./tools/cmd/signing-e2e
