#!/bin/bash
set -euo pipefail

ENV_FILE=/run/emisar/env
install -d -m 0700 /run/emisar
: > "$ENV_FILE"
chmod 600 "$ENV_FILE"

token_response=$(curl --fail --silent --show-error --retry 5 --retry-delay 2 \
  --retry-connrefused --connect-timeout 5 --max-time 30 \
  -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token)
TOKEN=$(printf '%s' "$token_response" | grep -oE '"access_token": ?"[^"]+"' | cut -d'"' -f4 || true)
[ -n "$TOKEN" ] || { echo "no metadata access token" >&2; exit 1; }

# $1 = secret id, $2 = exact version, $3 = env var. Every rendered secret is
# required and an out-of-band `latest` version can never change this VM's input.
fetch_secret() {
  local body status data value
  body=$(mktemp /run/emisar/secret.XXXXXX)
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

%{ for secret_id, secret in runtime_secrets ~}
fetch_secret "${secret_id}" "${secret.version}" "${secret.env_name}"
%{ endfor ~}

grep -q '^SECRET_KEY_BASE=' "$ENV_FILE" || { echo "SECRET_KEY_BASE missing from Secret Manager" >&2; exit 1; }
%{ if release_cookie_ready ~}
grep -q '^RELEASE_COOKIE=' "$ENV_FILE" || { echo "RELEASE_COOKIE missing from Secret Manager" >&2; exit 1; }
%{ else ~}
# Preserve the pre-cutover cookie until the separate secret is seeded with this
# exact value. That keeps old and new VMs in one BEAM cluster during the rollout.
SKB=$(grep '^SECRET_KEY_BASE=' "$ENV_FILE" | cut -d= -f2-)
printf 'RELEASE_COOKIE=%s\n' "$(printf 'emisar-release-cookie:%s' "$SKB" | sha256sum | cut -d' ' -f1)" >> "$ENV_FILE"
%{ endif ~}
%{ if database_auth_mode == "password" ~}
grep -q '^DATABASE_URL=' "$ENV_FILE" || { echo "DATABASE_URL missing from Secret Manager" >&2; exit 1; }
%{ endif ~}

NODE_IP=$(curl --fail --silent --show-error --retry 5 --retry-delay 2 \
  --retry-connrefused --connect-timeout 5 --max-time 30 \
  -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
[ -n "$NODE_IP" ] || { echo "no instance internal IP" >&2; exit 1; }

{
  printf 'PHX_HOST=%s\n' "${domain}"
  printf 'MAILER_FROM_EMAIL=%s\n' "${mailer_from_email}"
  printf 'PORT=%s\n' "${app_port}"
  printf 'FORCE_SSL=true\n'
  printf 'NODE_IP=%s\n' "$NODE_IP"
  printf 'EMISAR_CLUSTER_PROJECT=%s\n' "${project_id}"
  printf 'EMISAR_CLUSTER_VALUE=%s\n' "${cluster_value}"
  printf 'POOL_SIZE=%s\n' "${database_pool_size}"
%{ if database_role != "" ~}
  printf 'DATABASE_ROLE=%s\n' "${database_role}"
%{ endif ~}
%{ if database_auth_mode == "iam" ~}
  printf 'DATABASE_HOST=127.0.0.1\n'
  printf 'DATABASE_PORT=5432\n'
  printf 'DATABASE_USER=%s\n' "${database_user}"
  printf 'DATABASE_NAME=%s\n' "${database_name}"
%{ else ~}
  printf 'DATABASE_SSL=1\n'
  printf 'DATABASE_SSL_CACERTFILE=/etc/emisar/db-server-ca.pem\n'
%{ endif ~}
%{ if disable_billing ~}
  printf 'EMISAR_DISABLE_BILLING=1\n'
%{ endif ~}
} >> "$ENV_FILE"

%{ if database_auth_mode == "iam" ~}
curl --fail --silent --show-error --retry 30 --retry-delay 2 \
  --retry-connrefused --connect-timeout 2 --max-time 5 \
  http://127.0.0.1:9090/readiness >/dev/null
%{ endif ~}

docker rm -f emisar 2>/dev/null || true
exec docker run --rm --name emisar --network host --env-file "$ENV_FILE" \
%{ if database_auth_mode == "password" ~}
  -v /etc/emisar/db-server-ca.pem:/etc/emisar/db-server-ca.pem:ro \
%{ endif ~}
  ${container_image}
