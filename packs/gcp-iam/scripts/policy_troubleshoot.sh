#!/bin/bash
set -euo pipefail

project=$1 principal=$2 permission=$3 resource=$4
api=${CLOUDSDK_API_ENDPOINT_OVERRIDES_POLICYTROUBLESHOOTER:-https://policytroubleshooter.googleapis.com}
api=${api%/}
if [[ ! $api =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  printf '%s\n' 'Policy Troubleshooter endpoint must be an HTTPS origin without credentials, path or query.' >&2
  exit 2
fi
umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-policy-troubleshooter.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

# A short-lived credential stays in memory and curl stdin, never argv or output.
if ! access=$(gcloud auth print-access-token --quiet 2>/dev/null | head -c 16385); then
  printf '%s\n' 'Could not obtain a gcloud access credential.' >&2
  exit 1
fi
if [[ ${#access} -gt 16384 || ! $access =~ ^[A-Za-z0-9._~+/-]+=*$ ]]; then
  printf '%s\n' 'gcloud returned an invalid access credential.' >&2
  exit 1
fi

jq -nc --arg principal "$principal" --arg permission "$permission" --arg resource "$resource" \
  --arg name "$5" --arg service "$6" --arg type "$7" --arg time "$8" --arg ip "$9" --arg port "${10}" '
  {resource: ({name: $name, service: $service, type: $type} | with_entries(select(.value != ""))),
   request: (if $time == "" then {} else {receiveTime: $time} end),
   destination: ({ip: $ip} + (if $port == "0" then {} else {port: $port} end) | with_entries(select(.value != "")))}
  | with_entries(select(.value != {})) as $context
  | {accessTuple: ({principal: $principal, permission: $permission, fullResourceName: $resource}
    + (if $context == {} then {} else {conditionContext: $context} end))}
' >"$tmp/request"

# Independent capture bound also works on curl versions before 8.4, where
# --max-filesize alone does not bound a response without Content-Length.
if printf 'header = "Authorization: Bearer %s"\n' "$access" |
  curl -q --config - --fail-with-body --silent --show-error --globoff --proto '=https' \
    --connect-timeout 10 --max-time 45 --max-redirs 0 --max-filesize 1048576 \
    --header "x-goog-user-project: $project" --header 'Content-Type: application/json' \
    --data-binary "@$tmp/request" "$api/v3/iam:troubleshoot" 2>/dev/null |
  head -c 1048577 >"$tmp/response"; then
  statuses=("${PIPESTATUS[@]}")
else
  statuses=("${PIPESTATUS[@]}")
fi
unset access
if (($(wc -c <"$tmp/response") > 1048576 || statuses[1] == 63)); then
  printf '%s\n' 'Policy Troubleshooter response exceeds the 1 MiB byte budget.' >&2
  exit 1
fi
if ((statuses[0] != 0 || statuses[2] != 0)); then
  printf '%s\n' 'Could not capture the bounded Policy Troubleshooter response.' >&2
  exit 1
fi
if ((statuses[1] != 0)); then
  printf 'Policy Troubleshooter API request failed (client exit %s).\n' "${statuses[1]}" >&2
  jq -ce '{error: {code: .error.code, status: (.error.status // "" | tostring | .[:64]),
    message: (.error.message // "" | tostring | .[:512])}}' "$tmp/response" >&2 2>/dev/null || true
  exit "${statuses[1]}"
fi
# Keep policy membership, conditions, per-expression errors and deny evaluation.
# A successful diagnostic can report CANNOT_ACCESS or UNKNOWN_*; none is mapped
# to a Boolean, and a granted allow binding cannot override the overall result.
jq -ce 'if type == "object" and (.overallAccessState as $state |
  ["OVERALL_ACCESS_STATE_UNSPECIFIED", "CAN_ACCESS", "CANNOT_ACCESS", "UNKNOWN_INFO", "UNKNOWN_CONDITIONAL"] | index($state) != null)
  then . else error("invalid Policy Troubleshooter response: missing access state") end' "$tmp/response"
