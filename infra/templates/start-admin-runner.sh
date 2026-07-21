#!/bin/bash
set -euo pipefail

install -d -m 0700 /run/emisar-admin-runner

token_response=$(curl --fail --silent --show-error --retry 5 --retry-delay 2 \
  --retry-connrefused --connect-timeout 5 --max-time 30 \
  -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token)
TOKEN=$(printf '%s' "$token_response" | grep -oE '"access_token": ?"[^"]+"' | cut -d'"' -f4 || true)
[ -n "$TOKEN" ] || { echo "no metadata access token" >&2; exit 1; }

body=$(mktemp /run/emisar-admin-runner/secret.XXXXXX)
trap 'rm -f "$body"' EXIT
if ! status=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | \
  curl --silent --show-error --retry 5 --retry-delay 2 \
    --retry-connrefused --connect-timeout 5 --max-time 30 \
    -H @- -o "$body" -w '%%{http_code}' \
    "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/emisar-admin-runner-enrollment-key/versions/${enrollment_secret_version}:access"); then
  echo "Secret Manager enrollment-key request failed" >&2
  exit 1
fi
if [ "$status" != 200 ]; then
  echo "Secret Manager returned HTTP $status for the enrollment key" >&2
  exit 1
fi
data=$(grep -oE '"data": ?"[^"]+"' "$body" | cut -d'"' -f4 || true)
[ -n "$data" ] || { echo "Secret Manager returned no enrollment key" >&2; exit 1; }
EMISAR_ENROLLMENT_KEY=$(printf '%s' "$data" | base64 -d) || {
  echo "Secret Manager returned invalid enrollment-key data" >&2
  exit 1
}
printf '%s' "$EMISAR_ENROLLMENT_KEY" | grep -Eq '^emkey-enroll-[A-Za-z0-9_-]{16,}$' || {
  echo "Secret Manager returned an invalid enrollment key" >&2
  exit 1
}
export EMISAR_ENROLLMENT_KEY
rm -f "$body"
trap - EXIT

runner=/run/emisar-admin-runner/bin/emisar
expected_version="emisar version ${runner_version}"
installed_version=$($runner --version 2>/dev/null || true)
if [ "$installed_version" != "$expected_version" ]; then
  EMISAR_PACKS='' \
  BIN_DIR=/run/emisar-admin-runner/bin \
  ETC_DIR=/var/lib/emisar-admin-runner \
  DATA_DIR=/var/lib/emisar-admin-runner/data \
  LOG_DIR=/var/lib/emisar-admin-runner/log \
    /bin/bash /var/lib/emisar-admin-runner/install.sh \
      --version "${runner_version}" \
      --no-service \
      --yes \
      --packs ''
fi

[ "$($runner --version)" = "$expected_version" ]
test -f /var/lib/emisar-admin-runner/packs/emisar-admin/pack.yaml
test -x /var/lib/emisar-admin-runner/packs/emisar-admin/scripts/callback.sh

for attempt in $(seq 1 60); do
  if docker exec emisar /app/bin/emisar pid >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" = 60 ]; then
    echo "local emisar release did not become available" >&2
    exit 1
  fi
  sleep 2
done

exec "$runner" connect --config /var/lib/emisar-admin-runner/config.yaml
