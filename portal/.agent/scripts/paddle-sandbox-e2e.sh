#!/usr/bin/env bash
# Sandbox billing e2e — a REAL purchase against the Paddle sandbox: catalog
# checkout → Paddle.js overlay → test card → webhook → subscription mirror.
#
# Prereqs (one-time):
#   * portal/.agent/secrets/paddle-sandbox.env — sandbox API key, client token,
#     the durable e2e notification destination id + its signing secret
#     (git-ignored; ask the account owner if missing).
#   * The SANDBOX default payment link set to http://localhost:4000/checkout
#     (dashboard-only: sandbox-vendors.paddle.com/checkout-settings — Paddle
#     refuses to create transactions until some payment link exists).
#   * ngrok authenticated (webhooks must reach localhost), Chrome, node deps
#     in .agent/scripts (npm install), the dev db container.
#
# Usage: portal/.agent/scripts/paddle-sandbox-e2e.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PORTAL="$(cd "$SCRIPTS/../.." && pwd)"
SECRETS="$PORTAL/.agent/secrets/paddle-sandbox.env"

[ -f "$SECRETS" ] || { echo "FAIL: $SECRETS missing (sandbox credentials)"; exit 1; }
# shellcheck source=/dev/null
source "$SECRETS"
: "${PADDLE_API_KEY:?}" "${PADDLE_CLIENT_TOKEN:?}" "${PADDLE_WEBHOOK_SECRET:?}" "${PADDLE_E2E_NTFSET:?}"
case "$PADDLE_API_KEY" in
  *_sdbx_*) ;;
  *) echo "FAIL: refusing to run the e2e against a NON-sandbox key"; exit 1 ;;
esac

echo "==> dev db"
docker compose -f "$PORTAL/docker-compose.yml" up -d db >/dev/null
until docker exec portal-db-1 pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

echo "==> reset demo account to free (delete its subscription mirror)"
docker exec portal-db-1 psql -U postgres -d emisar_dev -qc \
  "delete from subscriptions where account_id = (select id from accounts where slug='demo');"

echo "==> tunnel"
if ! curl -sf http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
  (nohup ngrok http 4000 >/tmp/ngrok.log 2>&1 &)
  sleep 4
fi
TUNNEL="$(curl -sf http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[0].public_url')"
[ -n "$TUNNEL" ] && [ "$TUNNEL" != "null" ] || { echo "FAIL: no ngrok tunnel"; exit 1; }
echo "    $TUNNEL"

echo "==> point the durable webhook destination at the tunnel"
curl -sf -X PATCH "https://sandbox-api.paddle.com/notification-settings/$PADDLE_E2E_NTFSET" \
  -H "Authorization: Bearer $PADDLE_API_KEY" -H "Content-Type: application/json" \
  -d "{\"destination\":\"$TUNNEL/webhooks/paddle\",\"active\":true}" >/dev/null

echo "==> dev server with sandbox creds"
STALE="$(lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null || true)"
[ -n "$STALE" ] && kill -9 $STALE 2>/dev/null || true
(cd "$PORTAL" && mix phx.server >/tmp/phx-e2e.log 2>&1 &)
for _ in $(seq 1 60); do
  curl -sf -o /dev/null http://localhost:4000/ && break
  sleep 2
done
curl -sf http://localhost:4000/checkout | grep -q 'data-sandbox="true"' ||
  { echo "FAIL: /checkout is not running sandbox Paddle.js"; exit 1; }

cleanup() {
  SERVER="$(lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null || true)"
  [ -n "$SERVER" ] && kill $SERVER 2>/dev/null || true
}
trap cleanup EXIT

echo "==> browser purchase (test card via the real overlay)"
(cd "$SCRIPTS" && node paddle-e2e.mjs)

echo "==> waiting for the subscription webhook to mirror"
ROW=""
for _ in $(seq 1 45); do
  ROW="$(docker exec portal-db-1 psql -U postgres -d emisar_dev -Atc \
    "select plan || '|' || status || '|' || entitlements::text from subscriptions
     where account_id = (select id from accounts where slug='demo');")"
  [ -n "$ROW" ] && break
  sleep 2
done

echo "    subscription: ${ROW:-<none>}"
case "$ROW" in
  team\|*runners_limit*) echo "PASS: sandbox purchase mirrored plan=team with entitlements" ;;
  "") echo "FAIL: no subscription row — webhook never landed"; exit 1 ;;
  *) echo "FAIL: unexpected mirror state: $ROW"; exit 1 ;;
esac
