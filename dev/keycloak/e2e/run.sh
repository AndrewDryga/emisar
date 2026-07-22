#!/usr/bin/env bash
#
# Host-side SSO end-to-end check. Runs tools/cmd/sso-e2e against published
# localhost URLs — the exact path a host browser takes, so a green run proves
# the host-browser SSO flow works. Stdlib Go only; no deps. For the active
# workspace, pass the URLs printed by `dev/run urls` after starting the server:
#
#   PORTAL_URL=http://localhost:<portal-port> \
#     KEYCLOAK_ISSUER=https://localhost:<keycloak-port>/realms/emisar \
#     ./dev/keycloak/e2e/run.sh
#
# (It can't run as a compose service: the flow uses plain localhost, and inside a
# container `localhost` is the container itself, not the host's published ports.)
#
set -euo pipefail
cd "$(dirname "$0")/../../.." # repo root, so the relative CA path resolves

PORTAL_URL="${PORTAL_URL:-http://localhost:4010}" \
  KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-https://localhost:8443/realms/emisar}" \
  KEYCLOAK_CA="${KEYCLOAK_CA:-dev/keycloak/certs/generated/ca.crt}" \
  PROVIDER_ID="${PROVIDER_ID:-11111111-1111-7111-8111-111111111111}" \
  SCIM_TOKEN="${SCIM_TOKEN:-dev-scim-token}" \
  KC_USER="${KC_USER:-alice}" \
  KC_PASS="${KC_PASS:-Sleep-tight-1234}" \
  ALICE_KC_ID="${ALICE_KC_ID:-a11ce000-0000-4000-8000-000000000001}" \
  exec go run ./tools/cmd/sso-e2e
