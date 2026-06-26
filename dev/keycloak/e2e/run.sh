#!/usr/bin/env bash
#
# Host-side SSO end-to-end check. Runs sso_e2e.py against the PUBLISHED localhost
# ports (portal localhost:4010, Keycloak localhost:8443) — the exact path a host
# browser takes, so a green run proves the host-browser SSO flow works. Stdlib
# Python 3 only; no deps. Run after the stack is up:
#
#   docker compose up -d db keycloak portal seeder
#   ./dev/keycloak/e2e/run.sh
#
# (It can't run as a compose service: the flow uses plain localhost, and inside a
# container `localhost` is the container itself, not the host's published ports.)
#
set -euo pipefail
cd "$(dirname "$0")/../../.." # repo root, so the relative CA path resolves

PORTAL_URL="${PORTAL_URL:-http://localhost:4010}" \
  KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-https://localhost:8443/realms/emisar}" \
  KEYCLOAK_CA="${KEYCLOAK_CA:-dev/keycloak/certs/ca.crt}" \
  PROVIDER_ID="${PROVIDER_ID:-11111111-1111-7111-8111-111111111111}" \
  SCIM_TOKEN="${SCIM_TOKEN:-ems-scim-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD}" \
  KC_USER="${KC_USER:-alice}" \
  KC_PASS="${KC_PASS:-Sleep-tight-1234}" \
  exec python3 dev/keycloak/e2e/sso_e2e.py
