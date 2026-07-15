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
# rotates it. Every discovery and dispatch call goes through the bridge over the
# in-network portal:4000 endpoint, exactly as on a real stdio client.
set -euo pipefail
cd "$(dirname "$0")/../../.." # repo root, so `docker compose` finds the stack

# The portal, runner, and bridge share the signed-envelope contract. Rebuild all
# three so a running development stack cannot make this cross-component check
# pass or fail against stale code.
echo "[signed-dispatch-e2e] building current portal + runner + mcp images (cached if unchanged)..."
docker compose --profile test build portal runner-signed mcp

# This check spans incompatible pre-release runner state formats by design. Its
# dedicated volume is test data, so start from an empty durable state instead of
# teaching the production runner to accept obsolete dispatch records.
echo "[signed-dispatch-e2e] resetting the enforcing runner's dedicated state..."
docker compose --profile test stop runner-signed >/dev/null
docker compose --profile test run --rm --no-deps -T --user root \
  --entrypoint /bin/sh runner-signed \
  -c 'find /var/lib/emisar -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'

echo "[signed-dispatch-e2e] bringing up portal + signing-init + runner-signed (profile: test)..."
docker compose --profile test up -d portal
docker compose --profile test up -d --force-recreate signing-init runner-signed

exec go run ./tools/cmd/signing-e2e
