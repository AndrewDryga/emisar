#!/bin/sh
set -eu
umask 077

project=$1
zone=$2
page_size=$3
page_cursor=$4
api_base=${CLOUDSDK_API_ENDPOINT_OVERRIDES_DNS:-https://dns.googleapis.com/dns/v1}
api_base=${api_base%/}
case "$api_base" in
  https://*) ;;
  *) printf '%s\n' 'Cloud DNS API endpoint must use HTTPS' >&2; exit 2 ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-gcp-dns-records.XXXXXX")
trap 'rm -f -- "$tmp/access" "$tmp/quota" "$tmp/diagnostic" "$tmp/response" "$tmp/status" "$tmp/projected"; rmdir -- "$tmp"' EXIT HUP INT TERM

# Credentials and curl diagnostics stay private. Validate stdin config syntax;
# no bearer credential is passed in argv or printed on authentication failure.
if ! gcloud auth print-access-token --quiet >"$tmp/access" 2>"$tmp/diagnostic"; then
  printf '%s\n' 'gcloud could not authenticate the Cloud DNS read' >&2
  exit 1
fi
if ! jq -Rse '
  if endswith("\n") then .[0:-1] else . end
  | length > 0 and utf8bytelength <= 16384
    and (explode | all((. >= 65 and . <= 90) or (. >= 97 and . <= 122)
      or (. >= 48 and . <= 57) or . == 46 or . == 95 or . == 126
      or . == 43 or . == 47 or . == 45 or . == 61))
' "$tmp/access" >/dev/null 2>"$tmp/diagnostic"; then
  printf '%s\n' 'gcloud returned an invalid access credential' >&2
  exit 1
fi
access_token=$(tr -d '\n' <"$tmp/access")
if ! gcloud config get billing/quota_project --quiet >"$tmp/quota" 2>"$tmp/diagnostic"; then
  printf '%s\n' 'gcloud could not read the quota-project configuration' >&2
  exit 1
fi
quota_project=$(tr -d '\n' <"$tmp/quota")
case "$quota_project" in
  ''|'(unset)'|CURRENT_PROJECT|CURRENT_PROJECT_WITH_FALLBACK|LEGACY) quota_project='' ;;
  *)
    if ! jq -Rse '
      def lower: . >= 97 and . <= 122;
      def digit: . >= 48 and . <= 57;
      if endswith("\n") then .[0:-1] else . end
      | explode as $chars
      | (length >= 1 and length <= 20 and ($chars | all(digit)))
        or (length >= 6 and length <= 30 and ($chars[0] | lower)
          and ($chars[-1] | lower or digit) and ($chars | all(lower or digit or . == 45)))
    ' "$tmp/quota" >/dev/null 2>"$tmp/diagnostic"; then
      printf '%s\n' 'gcloud quota project must be a concrete project ID or number' >&2
      exit 2
    fi
    ;;
esac

auth_config() {
  printf 'header = "Authorization: Bearer %s"\n' "$access_token"
  if [ -n "$quota_project" ]; then
    printf 'header = "X-Goog-User-Project: %s"\n' "$quota_project"
  fi
}
set -- --get --data-urlencode "maxResults=$page_size"
if [ -n "$page_cursor" ]; then
  set -- "$@" --data-urlencode "pageToken=$page_cursor"
fi
rc=0
auth_config | curl -q --config - --fail-with-body --silent --show-error --globoff \
  --proto '=https' --connect-timeout 10 --max-time 60 --max-filesize 4194304 \
  --output "$tmp/response" --write-out '%{http_code}' "$@" \
  "$api_base/projects/$project/managedZones/$zone/rrsets" \
  >"$tmp/status" 2>"$tmp/diagnostic" || rc=$?
status=$(tr -d '\n' <"$tmp/status")
if [ "$rc" -ne 0 ]; then
  printf 'Cloud DNS request failed (client code %s, HTTP %s)\n' "$rc" "$status" >&2
  # Preserve only an actual HTTP rejection, never an unprojected partial
  # successful response after a transport/size failure.
  case "$rc:$status" in
    22:4??|22:5??) head -c 16384 "$tmp/response" >&2 ;;
  esac
  exit "$rc"
fi
case "$status" in
  2??) ;;
  *) printf 'Cloud DNS request returned unexpected HTTP %s\n' "$status" >&2; exit 1 ;;
esac
if [ "$(wc -c <"$tmp/response")" -gt 4194304 ]; then
  printf '%s\n' 'Cloud DNS response exceeds the 4 MiB budget; use a smaller page_size' >&2
  exit 1
fi

if ! jq -cse --arg project "$project" --arg zone "$zone" --argjson page_size "$page_size" '
  def nonempty_string: type == "string" and length > 0;
  def record:
    type == "object" and (.name | nonempty_string) and (.type | nonempty_string)
    and (.ttl | type == "number" and . >= 0 and . <= 2147483647 and . == floor)
    and (if has("rrdatas") then .rrdatas | type == "array" and all(.[]; type == "string")
         else has("routingPolicy") end)
    and (if has("routingPolicy") then .routingPolicy | type == "object" else true end);
  def cursor:
    (.nextPageToken // "") as $value
    | ($value != "") as $more
    | ($value | utf8bytelength <= 1024 and (explode | all(. >= 32 and (. < 127 or . > 159)))) as $usable
    | {more_available: $more, cursor_omitted: ($more and ($usable | not)),
       next_page_cursor: (if $more and $usable then $value else null end)};
  if length != 1 or (.[0] | type != "object") then error("invalid page") else .[0] end
  | if has("error") or (has("nextPageToken") and (.nextPageToken | type != "string"))
       or (has("rrsets") and (.rrsets | type != "array")) then error("invalid page") else . end
  | (.rrsets // []) as $records
  | if ($records | length > $page_size or (all(.[]; record) | not)) then error("invalid record sets") else . end
  | {project: $project, zone: $zone,
     record_sets: [$records[] | {name, type, ttl, rrdatas: (.rrdatas // []),
                                routing_policy: has("routingPolicy")}]} + cursor
' "$tmp/response" >"$tmp/projected" 2>"$tmp/diagnostic"; then
  printf '%s\n' 'Cloud DNS returned a malformed or overfull record-set page' >&2
  exit 1
fi
if [ "$(wc -c <"$tmp/projected")" -gt 4194304 ]; then
  printf '%s\n' 'Cloud DNS output exceeds the 4 MiB budget; use a smaller page_size' >&2
  exit 1
fi
cat "$tmp/projected"
