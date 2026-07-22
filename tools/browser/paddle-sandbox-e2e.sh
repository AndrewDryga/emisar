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
#   * ngrok authenticated (webhooks must reach localhost), Chrome, and the node
#     dependencies installed by `dev/run setup`.
#
# Usage: dev/run e2e billing
set -euo pipefail

BROWSER_TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$BROWSER_TOOLS" rev-parse --show-toplevel)"
PORTAL="$ROOT/portal"
SECRETS="$PORTAL/.agent/secrets/paddle-sandbox.env"

[ -f "$SECRETS" ] || { echo "FAIL: $SECRETS missing (sandbox credentials)"; exit 1; }
# shellcheck source=/dev/null
source "$SECRETS"
: "${PADDLE_API_KEY:?}" "${PADDLE_CLIENT_TOKEN:?}" "${PADDLE_WEBHOOK_SECRET:?}" "${PADDLE_E2E_NTFSET:?}"
case "$PADDLE_API_KEY" in
  *_sdbx_*) ;;
  *) echo "FAIL: refusing to run the e2e against a NON-sandbox key"; exit 1 ;;
esac

SERVER_PID=""
NGROK_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  [ -z "$NGROK_PID" ] || kill "$NGROK_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> reset demo account to free (delete its subscription mirror)"
psql -h "$PGHOST" -p "$PGPORT" -U postgres -d emisar_dev -qc \
  "delete from subscriptions where account_id = (select id from accounts where slug='demo');"

echo "==> tunnel"
if ! curl -sf http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
  nohup ngrok http 4000 >/tmp/ngrok.log 2>&1 &
  NGROK_PID=$!
  sleep 4
fi
TUNNEL="$(curl -sf http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[0].public_url')"
[ -n "$TUNNEL" ] && [ "$TUNNEL" != "null" ] || { echo "FAIL: no ngrok tunnel"; exit 1; }
echo "    $TUNNEL"

echo "==> point the durable webhook destination at the tunnel"
curl -sf -X PATCH "https://sandbox-api.paddle.com/notification-settings/$PADDLE_E2E_NTFSET" \
  -H "Authorization: Bearer $PADDLE_API_KEY" -H "Content-Type: application/json" \
  -d "{\"destination\":\"$TUNNEL/webhooks/paddle\",\"active\":true}" >/dev/null

# Plain HTTP throughout: this Mac's security agent blocks browser TLS to
# private addresses, so the driver rewrites Paddle's forced-https checkout
# URL (https://localhost:4000/checkout?_ptxn=…) back to http in-flight.
echo "==> dev server with sandbox creds"
BASE="http://localhost:4000"
if (echo >/dev/tcp/127.0.0.1/4000) >/dev/null 2>&1; then
  echo "FAIL: localhost:4000 is already in use"
  exit 1
fi

(cd "$PORTAL" && exec mix phx.server >/tmp/phx-e2e.log 2>&1) &
SERVER_PID=$!
UP=0
for _ in $(seq 1 90); do
  curl -sf -o /dev/null "$BASE/healthz" && UP=1 && break
  sleep 2
done
if [ "$UP" != "1" ]; then
  echo "FAIL: dev server never came up — /tmp/phx-e2e.log tail:"
  tail -15 /tmp/phx-e2e.log
  exit 1
fi
curl -sf "$BASE/checkout" | grep -q 'data-sandbox="true"' ||
  { echo "FAIL: /checkout is not running sandbox Paddle.js"; exit 1; }

echo "==> browser purchase (test card via the real overlay)"
(cd "$BROWSER_TOOLS" && E2E_BASE="$BASE" node paddle-e2e.mjs)

echo "==> waiting for the subscription webhook to mirror"
ROW=""
for _ in $(seq 1 45); do
  ROW="$(psql -h "$PGHOST" -p "$PGPORT" -U postgres -d emisar_dev -Atc \
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
