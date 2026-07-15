#!/bin/bash
set -euo pipefail

ENV_FILE=/run/emisar-livebook/env
install -d -m 0700 /run/emisar-livebook
: > "$ENV_FILE"
chmod 600 "$ENV_FILE"

token_response=$(curl --fail --silent --show-error --retry 5 --retry-delay 2 \
  --retry-connrefused --connect-timeout 5 --max-time 30 \
  -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token)
TOKEN=$(printf '%s' "$token_response" | grep -oE '"access_token": ?"[^"]+"' | cut -d'"' -f4 || true)
[ -n "$TOKEN" ] || { echo "no metadata access token" >&2; exit 1; }

# $1 = secret id, $2 = exact version, $3 = env var. Both values are required;
# an out-of-band `latest` version can never change this VM's input.
fetch_secret() {
  local body status data value
  body=$(mktemp /run/emisar-livebook/secret.XXXXXX)
  if ! status=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | \
    curl --silent --show-error --retry 5 --retry-delay 2 \
      --retry-connrefused --connect-timeout 5 --max-time 30 \
      -H @- -o "$body" -w '%%{http_code}' \
      "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/$1/versions/$2:access"); then
    echo "Secret Manager request failed for $1 version $2" >&2
    rm -f "$body"
    return 1
  fi
  if [ "$status" != 200 ]; then
    echo "Secret Manager returned HTTP $status for required secret $1 version $2" >&2
    rm -f "$body"
    return 1
  fi
  data=$(grep -oE '"data": ?"[^"]+"' "$body" | cut -d'"' -f4 || true)
  rm -f "$body"
  [ -n "$data" ] || { echo "Secret Manager returned no payload for $1" >&2; return 1; }
  value=$(printf '%s' "$data" | base64 -d) || {
    echo "Secret Manager returned invalid base64 for $1" >&2
    return 1
  }
  [ -n "$value" ] || { echo "Secret Manager returned an empty value for $1" >&2; return 1; }
  case "$value" in
    *$'\n'*|*$'\r'*) echo "Secret $1 contains a newline and cannot enter a Docker env file" >&2; return 1 ;;
  esac
  printf '%s=%s\n' "$3" "$value" >> "$ENV_FILE"
}

fetch_secret "emisar-livebook-secret-key-base" "${livebook_secret_version}" "LIVEBOOK_SECRET_KEY_BASE"
fetch_secret "emisar-release-cookie" "${release_cookie_version}" "LIVEBOOK_COOKIE"

NODE_IP=$(curl --fail --silent --show-error --retry 5 --retry-delay 2 \
  --retry-connrefused --connect-timeout 5 --max-time 30 \
  -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
[ -n "$NODE_IP" ] || { echo "no instance internal IP" >&2; exit 1; }

# The backend ID is server-assigned, but Livebook must validate it as the IAP
# JWT audience. Resolve it at boot so the instance/backend graph stays acyclic.
backend_body=$(mktemp /run/emisar-livebook/backend.XXXXXX)
trap 'rm -f "$backend_body"' EXIT
BACKEND_ID=""
for _attempt in $(seq 1 60); do
  status=$(curl --silent --show-error --connect-timeout 5 --max-time 30 \
    -H "Authorization: Bearer $TOKEN" -o "$backend_body" -w '%%{http_code}' \
    "https://compute.googleapis.com/compute/v1/projects/${project_id}/global/backendServices/${livebook_backend_name}" || true)
  if [ "$status" = 200 ]; then
    BACKEND_ID=$(grep -oE '"id": ?"[0-9]+"' "$backend_body" | head -1 | grep -oE '[0-9]+' || true)
    [ -n "$BACKEND_ID" ] && break
  elif [ "$status" != 403 ] && [ "$status" != 404 ] && [ "$status" != 429 ] && [[ "$status" != 5* ]]; then
    echo "Compute API returned HTTP $status while resolving the IAP backend" >&2
    exit 1
  fi
  sleep 5
done
[ -n "$BACKEND_ID" ] || { echo "IAP backend did not become discoverable" >&2; exit 1; }

{
  printf 'LIVEBOOK_IP=0.0.0.0\n'
  printf 'LIVEBOOK_PORT=%s\n' "${livebook_port}"
  printf 'LIVEBOOK_HOME=/data\n'
  printf 'LIVEBOOK_DATA_PATH=/data/.livebook\n'
  printf 'LIVEBOOK_NODE=livebook@%s\n' "$NODE_IP"
  printf 'LIVEBOOK_IDENTITY_PROVIDER=google_iap:/projects/%s/global/backendServices/%s\n' "${project_number}" "$BACKEND_ID"
  printf 'LIVEBOOK_TOKEN_ENABLED=false\n'
  printf 'LIVEBOOK_PROXY_HEADERS=x-forwarded-for,x-forwarded-proto,x-forwarded-host\n'
  printf 'LIVEBOOK_LOG_FORMAT=json\n'
  printf 'LIVEBOOK_LOG_METADATA=users,event,session_mode\n'
  printf 'LIVEBOOK_APP_SERVICE_NAME=Emisar Livebook\n'
  printf 'LIVEBOOK_APP_SERVICE_URL=https://livebook.%s\n' "${domain}"
  printf 'DATABASE_URL=postgresql://%s@127.0.0.1:5432/%s?sslmode=disable\n' "${database_user_uri}" "${database_name}"
  printf 'PGHOST=127.0.0.1\n'
  printf 'PGPORT=5432\n'
  printf 'PGDATABASE=%s\n' "${database_name}"
  printf 'PGUSER=%s\n' "${database_user}"
  printf 'PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=%s\n' "${database_statement_timeout_ms}"
  printf 'EMISAR_DATABASE_ROLE=%s\n' "${database_role}"
  printf 'EMISAR_DATABASE_DEFAULT_TRANSACTION_READ_ONLY=on\n'
  printf 'EMISAR_DATABASE_STATEMENT_TIMEOUT_MS=%s\n' "${database_statement_timeout_ms}"
} >> "$ENV_FILE"

docker rm -f emisar-livebook 2>/dev/null || true
# Mix.install executes build tools from HOME. Docker tmpfs mounts default to
# noexec, so the isolated notebook workspace must opt into execution explicitly.
exec docker run --rm --name emisar-livebook --network host --stop-timeout 120 \
  --user 1000:1000 --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,size=512m \
  --tmpfs /app/tmp:rw,nosuid,nodev,size=64m \
  --tmpfs /home/livebook:rw,exec,nosuid,nodev,size=512m \
  --mount type=bind,src=/mnt/disks/emisar-livebook,dst=/data \
  --mount type=bind,src=/var/lib/emisar-livebook/tools,dst=/opt/emisar,readonly \
  --env-file "$ENV_FILE" \
  ${livebook_image}
