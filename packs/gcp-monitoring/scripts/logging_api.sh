#!/bin/sh
set -eu

mode=$1
project=$2
access_token=$(gcloud auth print-access-token --quiet)
api_base=${CLOUDSDK_API_ENDPOINT_OVERRIDES_LOGGING:-https://logging.googleapis.com}
api_base=${api_base%/}

case "$api_base" in
  https://*) ;;
  *)
    printf '%s\n' "Logging API endpoint must use HTTPS" >&2
    exit 2
    ;;
esac

auth_config() {
  printf 'header = "Authorization: Bearer %s"\n' "$access_token"
  printf 'header = "X-Goog-User-Project: %s"\n' "$project"
}

request() {
  auth_config | curl -q --config - --fail --silent --show-error --globoff \
    --proto '=https' --connect-timeout 10 --max-time 60 \
    --max-filesize 4194304 "$@"
}

umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-gcp-logging.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

case "$mode" in
  log-names)
    page_size=$3
    page_cursor=$4

    set -- --get --data-urlencode "pageSize=$page_size"
    if [ -n "$page_cursor" ]; then
      set -- "$@" --data-urlencode "pageToken=$page_cursor"
    fi
    request "$@" "$api_base/v2/projects/$project/logs" >"$tmp/response.json"

    jq -ce --argjson page_size "$page_size" '
      def controls_collapsed:
        (explode | map(if . <= 31 or (. >= 127 and . <= 159) then 0 else . end)) as $cs
        | [range($cs | length) |
            select(. == 0 or $cs[.] != 0 or $cs[. - 1] != 0) | $cs[.]]
        | map(if . == 0 then 32 else . end)
        | implode;
      def clipped($chars; $bytes):
        (. // "" | tostring | controls_collapsed) as $clean
        | ($clean | .[:$chars] |
           until(utf8bytelength <= $bytes; .[:-1])) as $cut
        | if $cut == $clean then $clean
          else ($cut | .[:$chars - 1]) + "…" end;
      def cursor:
        (. // "" | tostring) as $value
        | def chars_allowed:
            explode | all(.[];
              (. >= 48 and . <= 57) or
              (. >= 65 and . <= 90) or
              (. >= 97 and . <= 122) or
              . == 43 or . == 45 or . == 46 or . == 47 or . == 61 or
              . == 95 or . == 126);
        if $value == "" then {value: null, omitted: false}
          elif ($value | length) <= 1024 and
               ($value | utf8bytelength) <= 1024 and
               ($value | chars_allowed)
          then {value: $value, omitted: false}
          else {value: null, omitted: true}
          end;
      (.nextPageToken | cursor) as $cursor
      | {
          log_names: [(.logNames // [])[:$page_size][] |
            (. // "" | tostring) as $name |
            {
              name: ($name | clipped(240; 240)),
              truncated: (($name | length) > 240 or
                          ($name | utf8bytelength) > 240)
            }],
          next_page_cursor: $cursor.value,
          cursor_omitted: $cursor.omitted
        }' "$tmp/response.json"
    ;;

  log-entries)
    minimum_severity=$3
    resource_type=$4
    log_id=$5
    window_minutes=$6
    page_size=$7
    end_epoch=$(date -u +%s)
    start_epoch=$((end_epoch - window_minutes * 60))
    start_time=$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)
    recent_filter="timestamp >= \"$start_time\" AND severity >= $minimum_severity"
    if [ -n "$resource_type" ]; then
      recent_filter="$recent_filter AND resource.type = \"$resource_type\""
    fi
    if [ -n "$log_id" ]; then
      recent_filter="$recent_filter AND logName = \"projects/$project/logs/$log_id\""
    fi

    jq -nce \
      --arg resource "projects/$project" \
      --arg filter "$recent_filter" \
      --argjson page_size "$page_size" '
        {
          resourceNames: [$resource],
          filter: $filter,
          orderBy: "timestamp desc",
          pageSize: $page_size
        }
      ' >"$tmp/request.json"
    request --request POST \
      --header 'Content-Type: application/json' \
      --data-binary "@$tmp/request.json" \
      "$api_base/v2/entries:list" >"$tmp/response.json"
    printf '%s' "$access_token" >"$tmp/access-token"

    jq -ce \
      --argjson page_size "$page_size" \
      --rawfile access_token "$tmp/access-token" '
      def controls_collapsed:
        (explode | map(if . <= 31 or (. >= 127 and . <= 159) then 0 else . end)) as $cs
        | [range($cs | length) |
            select(. == 0 or $cs[.] != 0 or $cs[. - 1] != 0) | $cs[.]]
        | map(if . == 0 then 32 else . end)
        | implode;
      def clipped($chars; $bytes):
        (. // "" | tostring | controls_collapsed) as $clean
        | ($clean | .[:$chars] |
           until(utf8bytelength <= $bytes; .[:-1])) as $cut
        | if $cut == $clean then $clean
          else ($cut | .[:$chars - 1]) + "…" end;
      def scalar_text:
        if type == "string" or type == "number" or type == "boolean"
        then tostring else "" end;
      def message:
        (.textPayload //
         .jsonPayload.message //
         .jsonPayload.msg //
         .jsonPayload.event //
         .protoPayload.status.message //
         .protoPayload.methodName //
         "") | scalar_text;
      def access_token_redacted:
        if $access_token == "" then .
        else split($access_token) | join("[REDACTED]")
        end;
      {
          entries: [(.entries // [])[:$page_size][] |
            . as $entry |
            ($entry | message | access_token_redacted) as $message |
            {
              timestamp: ($entry.timestamp | clipped(40; 40)),
              severity: ($entry.severity | clipped(16; 16)),
              resource_type: ($entry.resource.type | clipped(64; 64)),
              log_name: ($entry.logName | clipped(160; 160)),
              message: ($message | clipped(200; 200)),
              message_truncated: (($message | length) > 200 or
                                  ($message | utf8bytelength) > 200)
            }],
          more_available: ((.nextPageToken // "") != "")
        }' "$tmp/response.json"
    ;;

  *)
    printf '%s\n' "unsupported Logging operation: $mode" >&2
    exit 2
    ;;
esac
