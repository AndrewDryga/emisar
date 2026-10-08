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
  # --fail-with-body, like gcp-cloudsql and gcp-billing: a GCP error body is
  # {"error": {"code", "message", "status"}}, and dropping it leaves the
  # operator with an exit code and nothing to act on.
  auth_config | curl -q --config - --fail-with-body --silent --show-error --globoff \
    --proto '=https' --connect-timeout 10 --max-time 60 \
    --max-filesize 4194304 "$@"
}

# Capture the response instead of streaming it, and print the error body the
# script would otherwise swallow: --fail-with-body writes the body to the
# destination, so on a 4xx/5xx `set -e` would end the run before anything read
# it and the EXIT trap would delete it, leaving the operator with curl's
# `(22)` line alone. curl's --max-filesize still bounds what reaches stderr.
request_to() {
  capture=$1
  shift
  rc=0
  request "$@" >"$capture" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -s "$capture" ]; then
      cat "$capture" >&2
    fi
    exit "$rc"
  fi
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
    request_to "$tmp/response.json" "$@" "$api_base/v2/projects/$project/logs"

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
    view_id=$8
    json_message=$9
    page_cursor=${10}
    now_epoch=$(date -u +%s)
    end_epoch=$now_epoch
    # A cursor is bounded query data, not authority. Bind every current argument
    # and rebuild the request here; never accept a cursor-supplied target/filter.
    query_fingerprint=$(jq -nc \
      --arg endpoint "$api_base" --arg project "$project" \
      --arg severity "$minimum_severity" --arg resource_type "$resource_type" \
      --arg log_id "$log_id" --arg view_id "$view_id" --arg message "$json_message" \
      --argjson window "$window_minutes" --argjson size "$page_size" \
      '[$endpoint,$project,$severity,$resource_type,$log_id,$window,$size,$view_id,$message]' | sha256sum)
    query_fingerprint=${query_fingerprint%% *}
    invalid_cursor() {
      printf '%s\n' 'Invalid Cloud Logging continuation; start a new query with an empty page_cursor.' >&2
      exit 2
    }
    provider_cursor=''
    if [ -n "$page_cursor" ]; then
      [ "${#page_cursor}" -le 1152 ] || invalid_cursor
      case "$page_cursor" in v1.*.*.*) ;; *) invalid_cursor ;; esac
      remaining=${page_cursor#v1.}
      end_epoch=${remaining%%.*}
      remaining=${remaining#*.}
      fingerprint=${remaining%%.*}
      provider_cursor=${remaining#*.}
      case "$end_epoch" in ''|0*|*[!0-9]*) invalid_cursor ;; esac
      [ "${#end_epoch}" -le 10 ] || invalid_cursor
      [ "$end_epoch" -le "$now_epoch" ] || invalid_cursor
      [ "$end_epoch" -ge "$((window_minutes * 60))" ] || invalid_cursor
      [ "$fingerprint" = "$query_fingerprint" ] || invalid_cursor
      [ -n "$provider_cursor" ] && [ "${#provider_cursor}" -le 1024 ] || invalid_cursor
      case "$provider_cursor" in *[!A-Za-z0-9+./=_~-]*) invalid_cursor ;; esac
    fi
    start_epoch=$((end_epoch - window_minutes * 60))
    start_time=$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)
    end_time=$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)
    recent_filter="timestamp >= \"$start_time\" AND timestamp <= \"$end_time\" AND severity >= $minimum_severity"
    if [ -n "$resource_type" ]; then
      recent_filter="$recent_filter AND resource.type = \"$resource_type\""
    fi
    if [ -n "$log_id" ]; then
      recent_filter="$recent_filter AND logName = \"projects/$project/logs/$log_id\""
    fi
    if [ -n "$json_message" ]; then
      recent_filter="$recent_filter AND jsonPayload.message = \"$json_message\""
    fi
    resource="projects/$project"
    if [ -n "$view_id" ]; then
      resource="$resource/locations/global/buckets/_Default/views/$view_id"
    fi

    jq -nce \
      --arg resource "$resource" \
      --arg filter "$recent_filter" \
      --arg page_cursor "$provider_cursor" \
      --argjson page_size "$page_size" '
        {
          resourceNames: [$resource],
          filter: $filter,
          orderBy: "timestamp desc",
          pageSize: $page_size
        }
        | if $page_cursor == "" then . else . + {pageToken: $page_cursor} end
      ' >"$tmp/request.json"
    request_to "$tmp/response.json" --request POST \
      --header 'Content-Type: application/json' \
      --data-binary "@$tmp/request.json" \
      "$api_base/v2/entries:list"
    printf '%s' "$access_token" >"$tmp/access-token"

    jq -ce \
      --argjson page_size "$page_size" \
      --arg anchor "$end_epoch" --arg fingerprint "$query_fingerprint" \
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
        then {value: ("v1." + $anchor + "." + $fingerprint + "." + $value), omitted: false}
        else {value: null, omitted: true}
        end;
      (.nextPageToken | cursor) as $cursor
      | (.nextPageToken // "") as $next_page_token
      |
      {
          entries: [(.entries // [])[:$page_size][] |
            . as $entry |
            ($entry | message | access_token_redacted) as $message |
            {
              timestamp: ($entry.timestamp | clipped(40; 40)),
              severity: ($entry.severity | clipped(16; 16)),
              resource_type: ($entry.resource.type | clipped(64; 64)),
              log_name: ($entry.logName | clipped(160; 160)),
              job: ($entry.jsonPayload.job | scalar_text | access_token_redacted | clipped(100; 100)),
              error: ($entry.jsonPayload.error | scalar_text | access_token_redacted | clipped(100; 100)),
              message: ($message | clipped(200; 200)),
              message_truncated: (($message | length) > 200 or
                                  ($message | utf8bytelength) > 200)
            }],
          more_available: ($next_page_token != ""),
          next_page_cursor: $cursor.value,
          cursor_omitted: $cursor.omitted
        }
      # Match runner canonical encoding: HTML stays literal, but
      # U+2028/U+2029 grow from three UTF-8 bytes to six escaped bytes.
      | (tojson) as $encoded
      | if .next_page_cursor != null and
           (($encoded | utf8bytelength) +
            ([$encoded | explode[] | select(. == 8232 or . == 8233)] | length) * 3) > 8192
        then .next_page_cursor = null | .cursor_omitted = true
        else . end' "$tmp/response.json"
    ;;

  *)
    printf '%s\n' "unsupported Logging operation: $mode" >&2
    exit 2
    ;;
esac
