#!/bin/sh
set -eu
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
cursor=''
log_id=${1:-healthcheck-large}
for page in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  /bin/sh /packs/gcp-monitoring/scripts/logging_api.sh log-entry-detail example-prod "$log_id" 2026-11-08T01:17:13.871966957Z harness-probe-001 '' "$cursor" >"$tmp/page"
  jq -e '.status == "found" or .status == "incomplete"' "$tmp/page" >/dev/null
  jq -jr .entry_json_excerpt "$tmp/page" >>"$tmp/entry"
  cursor=$(jq -r '.next_page_cursor // ""' "$tmp/page")
  if [ -z "$cursor" ]; then
    [ "$page" -gt 1 ]
    expected=$(jq -er .entry_sha256 "$tmp/page")
    digest=$(sha256sum "$tmp/entry");digest=${digest%% *}
    [ "$digest" = "$expected" ]
    jq -e '.jsonPayload.healthCheckProbeResult.detailedHealthState == "TIMEOUT" and (.jsonPayload.oversized | length) > 4096' "$tmp/entry" >/dev/null
    printf '%s\n' 'complete entry preserved across bounded excerpts'
    exit 0
  fi
done
printf '%s\n' 'detail did not complete within the fixture bound' >&2
exit 1
