#!/bin/bash
set -euo pipefail
# Validate provider strings before command substitution can drop NUL/newline bytes.
ascii_filter='def ascii_text: if type == "string" then all(explode[]; . >= 32 and . <= 126) else false end;'

fail() { printf '%s\n' "$1" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Expected project, secret and version.'
project=$1 secret=$2 version=$3
[[ $project =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail 'Invalid Google Cloud project ID.'
[[ $secret =~ ^[A-Za-z0-9_-]{1,255}$ ]] || fail 'Invalid Secret Manager secret ID.'
[[ $version == latest || $version =~ ^[1-9][0-9]{0,31}$ ]] || fail 'Invalid Secret Manager version selector.'

umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-secret-version.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
# Auth stdout is private and independently capped; diagnostics are discarded.
# GNU timeout bounds credential refresh and kills a stuck child after its grace.
set +e
timeout --kill-after=1s 10s gcloud auth print-access-token --quiet 2>/dev/null |
  head -c 4097 >"$tmp/access"
codes=("${PIPESTATUS[@]}")
set -e
[[ $(wc -c <"$tmp/access") -le 4096 ]] || fail 'gcloud credential response exceeds the byte budget.'
[[ ${codes[0]} == 0 && ${codes[1]} == 0 ]] || fail 'Could not obtain a bounded gcloud access token.'
access=$(cat "$tmp/access")
[[ $access =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || fail 'gcloud returned an invalid access token.'

# The caller cannot select an origin, method, query, request body or :access.
url="https://secretmanager.googleapis.com/v1/projects/$project/secrets/$secret/versions/$version?fields=name,state,createTime,destroyTime"
set +e
printf 'header = "Authorization: Bearer %s"\n' "$access" |
  curl -q --config - --fail-with-body --silent --globoff --proto '=https' \
    --max-redirs 0 --connect-timeout 5 --max-time 35 --max-filesize 65536 \
    --header 'Accept-Encoding: identity' --request GET \
    --write-out '%{stderr}%{http_code}' "$url" 2>"$tmp/status" |
  head -c 65537 >"$tmp/response"
codes=("${PIPESTATUS[@]}")
set -e
[[ $(wc -c <"$tmp/response") -le 65536 && ${codes[1]} != 63 ]] || fail 'Secret Manager metadata exceeds the 64 KiB byte budget.'
[[ ${codes[0]} == 0 && ${codes[2]} == 0 ]] || fail 'Could not capture the bounded Secret Manager response.'
status=$(cat "$tmp/status")
if [[ $status != 200 || ${codes[1]} != 0 ]]; then
  [[ $status =~ ^[0-9]{3}$ ]] || status=000
  printf 'Secret Manager metadata request failed (HTTP %s; client exit %s).\n' "$status" "${codes[1]}" >&2
  # Preserve bounded vendor codes, never error messages/details or the envelope.
  code=$(jq -er '.error.code | select(type == "number" and . == floor and . >= 100 and . <= 599)' "$tmp/response" 2>/dev/null) || code=''
  state=$(jq -er "$ascii_filter .error.status | select(ascii_text and length <= 64)" "$tmp/response" 2>/dev/null) || state=''
  if [[ $code =~ ^[0-9]{3}$ && $state =~ ^[A-Z_]{1,64}$ ]]; then
    printf 'Google API code %s: %s\n' "$code" "$state" >&2
  fi
  exit 1
fi
jq -e 'type == "object"' "$tmp/response" >/dev/null 2>&1 || fail 'Secret Manager metadata must be a JSON object.'
name=$(jq -er "$ascii_filter .name | select(ascii_text and length <= 345)" "$tmp/response" 2>/dev/null) || fail 'Secret Manager returned an invalid version resource name.'
[[ $name =~ ^projects/([a-z][a-z0-9-]{4,28}[a-z0-9]|[1-9][0-9]{0,19})/secrets/([A-Za-z0-9_-]{1,255})/versions/([1-9][0-9]{0,31})$ ]] || fail 'Secret Manager returned an unsupported version resource name.'
returned_project=${BASH_REMATCH[1]} returned_secret=${BASH_REMATCH[2]} returned_version=${BASH_REMATCH[3]}
# The fixed authenticated route binds a canonical project number to the request;
# this metadata response alone cannot independently map that number to its ID.
[[ $returned_project == "$project" || $returned_project =~ ^[1-9][0-9]{0,19}$ ]] || fail 'Secret Manager returned a different project ID.'
[[ $returned_secret == "$secret" ]] || fail 'Secret Manager returned a different secret ID.'
[[ $version == latest || $returned_version == "$version" ]] || fail 'Secret Manager returned a different version ID.'
state=$(jq -er "$ascii_filter .state | select(ascii_text and length <= 9)" "$tmp/response" 2>/dev/null) || fail 'Secret Manager returned an invalid version state.'
case $state in ENABLED|DISABLED|DESTROYED) ;; *) fail 'Secret Manager returned an invalid version state.' ;; esac
created=$(jq -er "$ascii_filter .createTime | select(ascii_text and length <= 30)" "$tmp/response" 2>/dev/null) || fail 'Secret Manager returned an invalid creation timestamp.'
destroyed=$(jq -er "$ascii_filter if .destroyTime == null then \"\" else .destroyTime | select(ascii_text and length <= 30 and length > 0) end" "$tmp/response" 2>/dev/null) || fail 'Secret Manager returned an invalid destruction timestamp.'
timestamp='^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?Z$'
[[ $created =~ $timestamp && ${BASH_REMATCH[1]} != 0000 ]] || fail 'Secret Manager returned an invalid creation timestamp.'
if [[ -n $destroyed ]]; then
  [[ $state == DESTROYED && $destroyed =~ $timestamp && ${BASH_REMATCH[1]} != 0000 ]] || fail 'Secret Manager returned an invalid destruction timestamp.'
fi
jq -nc --arg name "$name" --arg state "$state" --arg created "$created" --arg destroyed "$destroyed" \
  '{name: $name, state: $state, create_time: $created, destroy_time: (if $destroyed == "" then null else $destroyed end)}'
