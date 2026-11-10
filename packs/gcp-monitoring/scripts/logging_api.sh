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

  log-entry-detail)
    log_id=$3
    entry_time=$4
    insert_id=$5
    view_id=$6
    page_cursor=$7
    invalid_detail() {
      printf '%s\n' 'Invalid Cloud Logging detail selector or continuation; use the exact log ID, UTC timestamp and unchanged arguments.' >&2
      exit 2
    }
    second=${entry_time%%.*}
    case "$entry_time" in *.*) second="${second}Z" ;; esac
    canonical=$(date -u -d "$entry_time" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || invalid_detail
    [ "$canonical" = "$second" ] || invalid_detail
    selected_time=$(date -u -d "$entry_time" +%Y-%m-%dT%H:%M:%S.%NZ)
    entry_epoch=$(date -u -d "$entry_time" +%s)
    [ "$entry_epoch" -ge 0 ] && [ "$entry_epoch" -le "$(date -u +%s)" ] || invalid_detail
    full_log_name="projects/$project/logs/$log_id"
    resource="projects/$project"
    if [ -n "$view_id" ]; then
      resource="$resource/locations/global/buckets/_Default/views/$view_id"
    fi
    fingerprint=$(jq -nc --arg endpoint "$api_base" --arg resource "$resource" \
      --arg log "$full_log_name" --arg timestamp "$entry_time" --arg id "$insert_id" \
      '[$endpoint,$resource,$log,$timestamp,$id]' | sha256sum)
    fingerprint=${fingerprint%% *}
    cursor_kind=''
    provider_cursor=''
    first_source=''
    first_digest=''
    offset=0
    if [ -n "$page_cursor" ]; then
      [ "${#page_cursor}" -le 3072 ] || invalid_detail
      case "$page_cursor" in v1.s.*) cursor_kind=s ;; v1.d.*) cursor_kind=d ;; *) invalid_detail ;; esac
      encoded=${page_cursor#v1.}
      encoded=${encoded#*.}
      jq -nce --arg encoded "$encoded" --arg scope "$fingerprint" --arg kind "$cursor_kind" '
        def hex: type == "string" and length == 64 and
          (explode | all(.[]; (. >= 48 and . <= 57) or (. >= 97 and . <= 102)));
        def provider:
          type == "string" and utf8bytelength <= 1024 and
          (explode | all(.[]; (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or
            (. >= 97 and . <= 122) or . == 43 or . == 45 or . == 46 or . == 47 or
            . == 61 or . == 95 or . == 126));
        ($encoded | @base64d | fromjson)
        | select(type == "array" and length == 4 and .[0] == $scope)
        | select(if $kind == "s" then
            (.[1] | provider and length > 0) and
            ((.[2] == null and .[3] == null) or ((.[2] | provider) and (.[3] | hex)))
          else (.[1] | provider) and (.[2] | hex) and
            (.[3] | type == "number" and . == floor and . > 0 and . <= 4194304) end)' \
        >"$tmp/cursor.json" 2>/dev/null || invalid_detail
      provider_cursor=$(jq -r '.[1]' "$tmp/cursor.json")
      if [ "$cursor_kind" = s ]; then
        first_source=$(jq -r '.[2] // ""' "$tmp/cursor.json")
        first_digest=$(jq -r '.[3] // ""' "$tmp/cursor.json")
      else
        first_digest=$(jq -r '.[2]' "$tmp/cursor.json")
        offset=$(jq -r '.[3]' "$tmp/cursor.json")
      fi
    fi
    read_detail() {
      jq -nce --arg resource "$resource" --arg log "$full_log_name" \
        --arg timestamp "$entry_time" --arg id "$insert_id" --arg cursor "$1" '
        {resourceNames: [$resource], orderBy: "timestamp desc", pageSize: 2,
         filter: ("timestamp = " + ($timestamp | tojson) + " AND logName = " + ($log | tojson) +
           (if $id == "" then "" else " AND insertId = " + ($id | tojson) end))}
        | if $cursor == "" then . else . + {pageToken: $cursor} end' >"$tmp/request.json"
      request_to "$2" --request POST --max-time 30 --header 'Content-Type: application/json' \
        --data-binary "@$tmp/request.json" "$api_base/v2/entries:list"
      jq -e --arg log "$full_log_name" --arg id "$insert_id" '
        (.entries // []) as $entries
        | ($entries | type == "array" and length <= 2) and
          all($entries[]; type == "object" and .logName == $log and
            (.timestamp | type == "string" and length <= 40) and
            (if has("insertId") then (.insertId | type == "string") else true end) and
            ($id == "" or .insertId == $id))' "$2" >/dev/null || invalid_detail
      jq -r '.entries // [] | .[] | .timestamp' "$2" >"$tmp/timestamps"
      while IFS= read -r returned_time; do
        returned_time=$(date -u -d "$returned_time" +%Y-%m-%dT%H:%M:%S.%NZ 2>/dev/null) || invalid_detail
        [ "$returned_time" = "$selected_time" ] || invalid_detail
      done <"$tmp/timestamps"
    }
    canonical_entry() {
      jq -jre --rawfile access_token "$tmp/access-token" '
        def safe_text:
          if $access_token == "" then . else split($access_token) | join("[REDACTED]") end
          | . as $text | (ascii_downcase | index("bearer ")) as $position
          | if $position == null then $text else $text[:$position + 7] + "[REDACTED]" end;
        def sensitive_name:
          ascii_downcase as $name
          | ["password","passwd","secret","credential","authorization","token","apikey","api_key","privatekey","private_key"]
          | any(.[]; . as $word | $name | contains($word));
        def sanitized:
          if type == "object" then to_entries | map(if (.key | sensitive_name) then .value = "[REDACTED]"
            else .value |= sanitized end) | sort_by(.key) | from_entries
          elif type == "array" then map(sanitized)
          elif type == "string" then safe_text else . end;
        .entries[0] | sanitized | tojson' "$1" >"$tmp/content.json"
      digest=$(sha256sum "$tmp/content.json")
      digest=${digest%% *}
    }
    printf '%s' "$access_token" >"$tmp/access-token"
    read_detail "$provider_cursor" "$tmp/current.json"
    count=$(jq -r '.entries // [] | length' "$tmp/current.json")
    next_provider=$(jq -er '
      (.nextPageToken // "") | select(type == "string" and utf8bytelength <= 1024 and
        (explode | all(.[]; (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or
          (. >= 97 and . <= 122) or . == 43 or . == 45 or . == 46 or . == 47 or
          . == 61 or . == 95 or . == 126)))' "$tmp/current.json") || invalid_detail
    if [ -n "$next_provider" ] && [ "$next_provider" = "$provider_cursor" ]; then
      invalid_detail
    fi
    selected="$tmp/current.json"
    detail_cursor=''
    status=not_found
    if [ "$cursor_kind" = d ]; then
      [ "$count" -eq 1 ] || invalid_detail
      canonical_entry "$selected"
      [ "$digest" = "$first_digest" ] || invalid_detail
      status=found
    elif [ -n "$first_digest" ] && { [ "$count" -gt 0 ] || [ -z "$next_provider" ]; }; then
      # A search can yield its sole match before its last (empty) provider page.
      # Re-read that exact page rather than lose the earlier payload or ask for an export.
      read_detail "$first_source" "$tmp/first.json"
      [ "$(jq -r '.entries // [] | length' "$tmp/first.json")" -eq 1 ] || invalid_detail
      canonical_entry "$tmp/first.json"
      [ "$digest" = "$first_digest" ] || invalid_detail
      if [ "$count" -gt 0 ]; then
        jq -n --slurpfile first "$tmp/first.json" --slurpfile current "$tmp/current.json" \
          '{entries: [$first[0].entries[0],$current[0].entries[0]]}' >"$tmp/ambiguous.json"
        selected="$tmp/ambiguous.json"
        status=ambiguous
      else
        selected="$tmp/first.json"
        provider_cursor=$first_source
        status=found
      fi
    elif [ "$count" -gt 1 ]; then
      status=ambiguous
    elif [ -n "$next_provider" ]; then
      status=incomplete
      if [ "$count" -eq 1 ] && [ -z "$first_digest" ]; then
        canonical_entry "$selected"
        first_source=$provider_cursor
        first_digest=$digest
      fi
      detail_cursor=$(jq -nr --arg scope "$fingerprint" --arg next "$next_provider" \
        --arg source "$first_source" --arg digest "$first_digest" '
        [$scope,$next, (if $digest == "" then null else $source end),
          (if $digest == "" then null else $digest end)] | @base64 | "v1.s." + .')
    elif [ "$count" -eq 1 ]; then
      status=found
      canonical_entry "$selected"
    fi
    jq -ce --arg status "$status" --arg log "$full_log_name" --arg timestamp "$entry_time" \
      --arg cursor "$detail_cursor" --rawfile access_token "$tmp/access-token" '
      def clip($n): .[:$n] | until(utf8bytelength <= $n; .[:-1]);
      def safe_text: if $access_token == "" then . else split($access_token) | join("[REDACTED]") end;
      {status: $status, log_name: $log, timestamp: $timestamp,
       insert_id: (if $status == "found" then (.entries[0].insertId // "" | safe_text | clip(256)) else "" end),
       identity_truncated: (if $status == "found" then ((.entries[0].insertId // "" | utf8bytelength) > 256) else false end),
       candidate_insert_ids: (if $status == "ambiguous" or $status == "incomplete" then
         [(.entries // [])[] | (.insertId // "" | safe_text) as $id
          | if ($id | utf8bytelength) <= 256 then $id else null end] else [] end),
       candidate_ids_omitted: (if $status == "ambiguous" or $status == "incomplete" then
         any((.entries // [])[]; (.insertId // "" | utf8bytelength) > 256) else false end),
       entry_json_excerpt: "", entry_json_characters: 0, excerpt_start: 0, excerpt_end: 0,
       entry_complete: false, entry_sha256: null,
       next_page_cursor: (if $cursor == "" then null else $cursor end)}' "$selected" >"$tmp/detail.json"
    if [ "$status" != found ]; then
      [ "$cursor_kind" != d ] || invalid_detail
      cat "$tmp/detail.json"
      exit 0
    fi
    jq -eRs 'length <= 4194304' "$tmp/content.json" >/dev/null
    jq -ce --arg digest "$digest" --arg scope "$fingerprint" --arg page "$provider_cursor" \
      --argjson offset "$offset" --rawfile content "$tmp/content.json" '
      def wire_size:
        tojson as $json | ($json | utf8bytelength) +
        ([$json | explode[] | select(. == 8232 or . == 8233)] | length) * 3;
      ($content | length) as $length
      | if $offset >= $length then error("Cloud Logging detail continuation is past the entry") else . end
      | .entry_sha256 = $digest | .entry_json_characters = $length | .excerpt_start = $offset
      | .entry_json_excerpt = $content[$offset:$offset + 4096]
      | def finish:
          .excerpt_end = ($offset + (.entry_json_excerpt | length))
          | .entry_complete = (.excerpt_end == $length)
          | .next_page_cursor = (if .entry_complete then null
              else ([$scope,$page,$digest,.excerpt_end] | @base64 | "v1.d." + .) end);
      finish
      | until((.entry_json_excerpt | utf8bytelength) <= 4096 and wire_size <= 8192;
          .entry_json_excerpt = .entry_json_excerpt[:-1] | finish)
      | if (.entry_json_excerpt | length) == 0 then error("Cloud Logging detail identity exceeds output budget") else . end' \
      "$tmp/detail.json"
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
    start_time=${11}
    end_time=${12}
    instance_id=${13}
    invalid_interval() {
      printf '%s\n' 'Invalid Cloud Logging interval or instance selector; supply both UTC bounds and use gce_instance for an instance ID.' >&2
      exit 2
    }
    if [ -n "$instance_id" ] && [ "$resource_type" != gce_instance ]; then
      invalid_interval
    fi
    absolute_end=''
    if [ -n "$start_time" ] || [ -n "$end_time" ]; then
      for timestamp in "$start_time" "$end_time"; do
        [ -n "$timestamp" ] || invalid_interval
        canonical=$(date -u -d "$timestamp" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || invalid_interval
        [ "$canonical" = "$timestamp" ] || invalid_interval
      done
      start_epoch=$(date -u -d "$start_time" +%s)
      absolute_end=$(date -u -d "$end_time" +%s)
      [ "$start_epoch" -ge 0 ] && [ "$absolute_end" -gt "$start_epoch" ] || invalid_interval
      [ "$((absolute_end - start_epoch))" -le 315360000 ] || invalid_interval
    fi
    now_epoch=$(date -u +%s)
    end_epoch=${absolute_end:-$now_epoch}
    [ "$end_epoch" -le "$now_epoch" ] || invalid_interval
    # A cursor is bounded query data, not authority. Bind every current argument
    # and rebuild the request here; never accept a cursor-supplied target/filter.
    query_fingerprint=$(jq -nc \
      --arg endpoint "$api_base" --arg project "$project" \
      --arg severity "$minimum_severity" --arg resource_type "$resource_type" \
      --arg log_id "$log_id" --arg view_id "$view_id" --arg message "$json_message" \
      --arg start "$start_time" --arg until_time "$end_time" --arg instance "$instance_id" \
      --argjson window "$window_minutes" --argjson size "$page_size" \
      '[$endpoint,$project,$severity,$resource_type,$log_id,$window,$size,$view_id,$message,$start,$until_time,$instance]' | sha256sum)
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
      if [ -n "$absolute_end" ]; then
        [ "$end_epoch" = "$absolute_end" ] || invalid_cursor
      else
        [ "$end_epoch" -ge "$((window_minutes * 60))" ] || invalid_cursor
      fi
      [ "$fingerprint" = "$query_fingerprint" ] || invalid_cursor
      [ -n "$provider_cursor" ] && [ "${#provider_cursor}" -le 1024 ] || invalid_cursor
      case "$provider_cursor" in *[!A-Za-z0-9+./=_~-]*) invalid_cursor ;; esac
    fi
    if [ -z "$absolute_end" ]; then
      start_epoch=$((end_epoch - window_minutes * 60))
      start_time=$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)
      end_time=$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)
    fi
    recent_filter="timestamp >= \"$start_time\" AND timestamp <= \"$end_time\" AND severity >= $minimum_severity"
    if [ -n "$resource_type" ]; then
      recent_filter="$recent_filter AND resource.type = \"$resource_type\""
    fi
    if [ -n "$instance_id" ]; then
      recent_filter="$recent_filter AND resource.labels.instance_id = \"$instance_id\""
    fi
    if [ -n "$log_id" ]; then
      recent_filter="$recent_filter AND logName = \"projects/$project/logs/$log_id\""
    fi
    if [ -n "$json_message" ]; then
      # An event line is the bare name or the name and its context
      # (`sweep.row_failed row=<id>`), so match the whole message or its first
      # word. The argument admits only [A-Za-z0-9._-]; `.` is the one RE2
      # metacharacter among them, and `[.]` spells it without an escape.
      message_regex=$(printf '%s\n' "$json_message" | sed 's/[.]/[.]/g')
      recent_filter="$recent_filter AND (jsonPayload.message = \"$json_message\" OR jsonPayload.message =~ \"^$message_regex \")"
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
