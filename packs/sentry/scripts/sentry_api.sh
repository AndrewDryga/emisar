#!/bin/bash
# Fixed Sentry API operations for the sentry pack. The caller selects one
# packaged subcommand; it never supplies shell code, a URL host, or a JSON
# body.
#
# SENTRY_URL is operator-set on the runner host (cloud region URL or a
# self-hosted base), so the transfer is pinned to http/https and globbing is
# off. The token rides a curl config document on stdin, never argv, so it
# stays out of /proc/<pid>/cmdline.
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -n "${SENTRY_AUTH_TOKEN:-}" ]] || fail "SENTRY_AUTH_TOKEN is required"

api_base="${SENTRY_URL:-https://sentry.io}"
api_base="${api_base%/}"
case "$api_base" in
  http://* | https://*) ;;
  *) fail "SENTRY_URL must be an http:// or https:// URL" ;;
esac
readonly api="$api_base/api/0"

auth_config() {
  printf 'header = "Authorization: Bearer %s"\n' "$SENTRY_AUTH_TOKEN"
}

request() {
  auth_config | curl -q --config - --fail --silent --show-error --globoff \
    --proto '=http,https' --connect-timeout 10 --max-time 60 \
    --max-filesize 8388608 "$@"
}

# Every model-visible application string is control-collapsed and bounded in
# both codepoints and UTF-8 bytes. The byte bound matters because JSON escaping
# can expand one source character into several output bytes.
readonly projection_helpers='
def controls_collapsed:
  (explode | map(if . <= 31 or (. >= 127 and . <= 159) then 0 else . end)) as $cs
  | [range($cs | length) | select(. == 0 or $cs[.] != 0 or $cs[. - 1] != 0) | $cs[.]]
  | map(if . == 0 then 32 else . end)
  | implode;

def clipped($chars; $encoded_bytes):
  (. // "" | tostring | controls_collapsed) as $clean
  | ($clean | .[:$chars] | until((tojson | utf8bytelength) <= $encoded_bytes; .[:-1]));
'

# Sentry paginates through Link response headers, so a body-only fetch would
# silently drop the continuation. Paged reads emit
# {results, pagination: {next_cursor, has_more}} instead of the raw body.
request_paged() {
  local response crlf=$'\r\n\r\n' headers body next_cursor="" has_more=false
  response=$(request --include "$@")
  headers=${response%%"$crlf"*}
  body=${response#*"$crlf"}
  if [[ "$headers" =~ rel=\"next\"\;\ results=\"true\"\;\ cursor=\"([^\"]+)\" ]]; then
    next_cursor="${BASH_REMATCH[1]}"
    has_more=true
  fi
  printf '%s' "$body" | jq -ce --arg cursor "$next_cursor" --argjson more "$has_more" \
    '{results: ., pagination: {next_cursor: (if $cursor == "" then null else $cursor end), has_more: $more}}'
}

with_cursor() {
  local cursor=$1
  shift
  if [[ -n "$cursor" ]]; then
    request_paged "$@" --data-urlencode "cursor=$cursor"
  else
    request_paged "$@"
  fi
}

list_organizations() {
  with_cursor "$1" --get "$api/organizations/"
}

list_projects() {
  with_cursor "$2" --get "$api/organizations/$1/projects/"
}

list_issues() {
  local org=$1 project=$2 query=$3 stats_period=$4 sort=$5 limit=$6 cursor=$7 response
  response=$(with_cursor "$cursor" --get "$api/projects/$org/$project/issues/" \
    --data-urlencode "query=$query" \
    --data-urlencode "statsPeriod=$stats_period" \
    --data-urlencode "sort=$sort" \
    --data-urlencode "limit=$limit")
  printf '%s' "$response" | jq -ce "$projection_helpers"'
    {
      results: [
        .results[] | {
          id: (.id | clipped(20; 20)),
          short_id: (.shortId | clipped(40; 40)),
          title: (.title | clipped(80; 80)),
          culprit: (.culprit | clipped(64; 64)),
          level: (.level | clipped(16; 16)),
          status: (.status | clipped(24; 24)),
          count: (.count | clipped(20; 20)),
          user_count: (.userCount | clipped(20; 20)),
          first_seen: (.firstSeen | clipped(32; 32)),
          last_seen: (.lastSeen | clipped(32; 32)),
          project_slug: (.project.slug | clipped(40; 40))
        }
      ],
      pagination: .pagination
    }'
}

issue_details() {
  request "$api/organizations/$1/issues/$2/" | jq -ce .
}

issue_latest_event() {
  local response
  response=$(request "$api/organizations/$1/issues/$2/events/latest/")
  printf '%s' "$response" | jq -ce "$projection_helpers"'
    def values($kind):
      [.entries[]? | select(.type == $kind) | .data.values[]?];
    (.request // ([.entries[]? | select(.type == "request") | .data] | first) // null) as $request
    | {
        event_id: (.eventID | clipped(48; 48)),
        date_created: (.dateCreated | clipped(32; 32)),
        platform: (.platform | clipped(32; 32)),
        exceptions: [
          values("exception")[] | {
            type: (.type | clipped(32; 32)),
            value: (.value | clipped(80; 80)),
            frames: [
              ((.stacktrace.frames // []) | reverse | .[:3] | reverse)[] | {
                filename: (.filename | clipped(48; 48)),
                function: (.function | clipped(40; 40)),
                line: (
                  if (.lineNo | type) == "number" and .lineNo >= 0 and .lineNo <= 2147483647
                  then (.lineNo | floor)
                  else null
                  end
                ),
                in_app: (if (.inApp | type) == "boolean" then .inApp else null end)
              }
            ]
          }
        ][:2],
        breadcrumbs: ([
          values("breadcrumbs")[] | {
            category: (.category | clipped(32; 32)),
            message: (.message | clipped(80; 80)),
            level: (.level | clipped(16; 16)),
            timestamp: (.timestamp | clipped(32; 32))
          }
        ] | reverse | .[:4] | reverse),
        request: (
          if $request == null then null
          else {
            method: ($request.method | clipped(12; 12)),
            url: ($request.url | clipped(80; 80)),
            query_string: (($request.query_string // $request.query) | clipped(80; 80))
          }
          end
        ),
        tags: [
          .tags[:4][]? | {
            key: (.key | clipped(32; 32)),
            value: (.value | clipped(48; 48))
          }
        ]
      }'
}

issue_tags() {
  request "$api/organizations/$1/issues/$2/tags/" | jq -ce .
}

list_releases() {
  with_cursor "$2" --get "$api/organizations/$1/releases/"
}

# Legacy DSNs embed a secret key ("public:secret@host" userinfo, plus a
# top-level secret field); modern clients never need it, so it is cut before
# the keys leave the runner.
list_project_keys() {
  request "$api/projects/$1/$2/keys/" | jq -ce '
    map(
      del(.secret)
      | if (.dsn | type) == "object" then .dsn |= del(.secret) else . end
    )'
}

set_key_active() {
  local org=$1 project=$2 key_id=$3 active=$4
  request --request PUT "$api/projects/$org/$project/keys/$key_id/" \
    --header 'Content-Type: application/json' \
    --data "$(jq -nc --argjson active "$active" '{isActive: $active}')" | jq -ce '
    del(.secret)
    | if (.dsn | type) == "object" then .dsn |= del(.secret) else . end'
}

set_issue_status() {
  local org=$1 issue_id=$2 status=$3 ignore_minutes=$4
  request --request PUT "$api/organizations/$org/issues/$issue_id/" \
    --header 'Content-Type: application/json' \
    --data "$(jq -nc --arg status "$status" --argjson minutes "$ignore_minutes" '
      {status: $status}
      + (if $status == "ignored" and $minutes > 0
         then {statusDetails: {ignoreDuration: $minutes}} else {} end)')" |
    jq -ce .
}

assign_issue() {
  local org=$1 issue_id=$2 assignee=$3
  request --request PUT "$api/organizations/$org/issues/$issue_id/" \
    --header 'Content-Type: application/json' \
    --data "$(jq -nc --arg assignee "$assignee" '{assignedTo: $assignee}')" |
    jq -ce .
}

org_stats() {
  local org=$1 stats_period=$2 interval=$3
  request --get "$api/organizations/$org/stats_v2/" \
    --data-urlencode "field=sum(quantity)" \
    --data-urlencode "groupBy=category" \
    --data-urlencode "groupBy=outcome" \
    --data-urlencode "statsPeriod=$stats_period" \
    --data-urlencode "interval=$interval" | jq -ce .
}

list_alert_rules() {
  request "$api/projects/$1/$2/rules/" | jq -ce .
}

command=${1:-}
shift || true
case "$command" in
  list-organizations) list_organizations "$@" ;;
  list-projects) list_projects "$@" ;;
  list-issues) list_issues "$@" ;;
  issue-details) issue_details "$@" ;;
  issue-latest-event) issue_latest_event "$@" ;;
  issue-tags) issue_tags "$@" ;;
  list-releases) list_releases "$@" ;;
  list-project-keys) list_project_keys "$@" ;;
  disable-project-key) set_key_active "$1" "$2" "$3" false ;;
  enable-project-key) set_key_active "$1" "$2" "$3" true ;;
  set-issue-status) set_issue_status "$@" ;;
  assign-issue) assign_issue "$@" ;;
  org-stats) org_stats "$@" ;;
  list-alert-rules) list_alert_rules "$@" ;;
  *) fail "unknown sentry operation" ;;
esac
