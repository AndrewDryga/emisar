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
  # --fail-with-body: Sentry answers a rejected request with {"detail": ...},
  # which names the missing scope or the unknown project.
  auth_config | curl -q --config - --fail-with-body --silent --show-error --globoff \
    --proto '=http,https' --connect-timeout 10 --max-time 60 \
    --max-filesize 8388608 "$@"
}

# Strings in the structured issue listing are bounded in codepoints and
# encoded UTF-8 bytes so the entire page fits its result limit.
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
# {results, pagination: {next_page_cursor, has_more}} instead of the raw body.
request_paged() {
  local response crlf=$'\r\n\r\n' headers body next_page_cursor="" has_more=false rc=0
  response=$(request --include "$@") || rc=$?
  headers=${response%%"$crlf"*}
  body=${response#*"$crlf"}
  # --fail-with-body kept the {"detail": ...} in $body, where `set -e` on the
  # assignment would have ended the run before anything printed it: the
  # operator would see curl's `(22)` line and nothing to act on. Only the body
  # goes out — the response headers are not the diagnosis and may carry a
  # cookie.
  if (( rc != 0 )); then
    if [[ -n "$body" ]]; then
      printf '%s\n' "$body" >&2
    fi
    exit "$rc"
  fi
  if [[ "$headers" =~ rel=\"next\"\;\ results=\"true\"\;\ cursor=\"([^\"]+)\" ]]; then
    next_page_cursor="${BASH_REMATCH[1]}"
    has_more=true
  fi
  printf '%s' "$body" | jq -ce --arg cursor "$next_page_cursor" --argjson more "$has_more" \
    '{results: ., pagination: {next_page_cursor: (if $cursor == "" then null else $cursor end), has_more: $more}}'
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
  local response rc=0
  response=$(request "$api/organizations/$1/issues/$2/events/latest/") || rc=$?
  # Same capture guard as request_paged: the error body is in $response, and
  # nothing else would ever print it.
  if (( rc != 0 )); then
    if [[ -n "$response" ]]; then
      printf '%s\n' "$response" >&2
    fi
    exit "$rc"
  fi
  # Emit one complete document or fail before the runner can cut it mid-field.
  # The limit includes the newline jq writes and matches the action stdout cap.
  printf '%s' "$response" | jq -rse '
    def entry($kind):
      first(.entries[]? | select(.type == $kind) | .data);
    def values($kind):
      .entries[]? | select(.type == $kind) | .data.values[]?;
    def frames:
      [.frames[]? | {
        filename: (.filename // ""),
        function: (.function // ""),
        line: .lineNo,
        in_app: .inApp
      }];

    if length == 1 and (.[0] | type) == "object" then .[0]
    else error("Expected one Sentry event object") end
    | (.request // entry("request") // null) as $request
    | (.stacktrace // entry("stacktrace") // null) as $stacktrace
    | (.logentry // entry("message") // null) as $logentry
    | {
        event_id: (.eventID // ""),
        date_created: (.dateCreated // ""),
        platform: (.platform // ""),
        title: .title,
        message: ((.message | select(. != "")) // $logentry.formatted // $logentry.message // ""),
        logentry: $logentry,
        contexts: (.contexts // {}),
        context: (.context // {}),
        exceptions: [
          values("exception") | {
            type: (.type // ""),
            value: (.value // ""),
            frames: ((.stacktrace // .rawStacktrace) | frames)
          }
        ],
        stacktrace: ($stacktrace | if . == null then null else {frames: frames} end),
        threads: [
          values("threads") | {
            id, name, current, crashed,
            frames: ((.stacktrace // .rawStacktrace) | frames)
          }
        ],
        breadcrumbs: [
          values("breadcrumbs") | {
            category: (.category // ""),
            message: (.message // ""),
            level: (.level // ""),
            timestamp: (.timestamp // "")
          }
        ],
        request: (
          if $request == null then null
          else {
            method: ($request.method // ""),
            url: ($request.url // ""),
            query_string: (($request.query_string // $request.query // "") | tostring)
          }
          end
        ),
        tags: (.tags // [])
      }
    | tojson
    | if utf8bytelength < 1048576 then . else error("Sentry event exceeds the 1 MiB output limit") end'
}

issue_tags() {
  request "$api/organizations/$1/issues/$2/tags/" | jq -ce .
}

list_issue_events() {
  local org=$1 issue_id=$2 limit=$3 cursor=$4 environment=$5 start=$6 end=$7 response
  local -a query=(--data-urlencode "full=true" --data-urlencode "per_page=$limit")
  if [[ -n "$environment" ]]; then
    query+=(--data-urlencode "environment=$environment")
  fi
  if [[ -n "$start" || -n "$end" ]]; then
    [[ -n "$start" && -n "$end" ]] || fail "Supply both start and end for the Sentry event window"
    query+=(--data-urlencode "start=$start" --data-urlencode "end=$end")
  fi
  # Sentry exposes custom context only with full=true. The full list
  # serializer exposes the release version as a tag.
  response=$(with_cursor "$cursor" --get "$api/organizations/$org/issues/$issue_id/events/" "${query[@]}")
  printf '%s' "$response" | jq -rse '
    if length == 1 and (.[0].results | type) == "array" then .[0]
    else error("Expected one Sentry issue event array") end
    | .results |= map({
        event_id: (.eventID // .id),
        date_created: (.dateCreated // (.endTimestamp | numbers | todateiso8601) // null),
        message: (.message // ""),
        release: (first(.tags[]? | select(.key == "release") | .value) // null),
        user: .user,
        tags: (.tags // []),
        contexts: (.contexts // {}),
        context: (.context // {})
      })
    | tojson
    | if utf8bytelength < 1048576 then .
      else error("Sentry issue event page exceeds the 1 MiB output limit. Use a smaller limit.") end'
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
  local org=$1 project=$2 limit=$3 cursor=$4
  with_cursor "$cursor" --get "$api/organizations/$org/workflows/" \
    --data-urlencode "project=$project" --data-urlencode "per_page=$limit"
}

command=${1:-}
shift || true
case "$command" in
  list-organizations) list_organizations "$@" ;;
  list-projects) list_projects "$@" ;;
  list-issues) list_issues "$@" ;;
  issue-details) issue_details "$@" ;;
  issue-latest-event) issue_latest_event "$@" ;;
  list-issue-events) list_issue_events "$@" ;;
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
