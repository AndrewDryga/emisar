#!/bin/sh
set -eu

mode=$1
project=$2
access_token=$(gcloud auth print-access-token --quiet)
api_base=${CLOUDSDK_API_ENDPOINT_OVERRIDES_MONITORING:-https://monitoring.googleapis.com}
api_base=${api_base%/}

case "$api_base" in
  https://*) ;;
  *)
    printf '%s\n' "Monitoring API endpoint must use HTTPS" >&2
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

# The runner's default redaction blanks any `token`-compound JSON key, so a raw
# `nextPageToken` never reaches the model and multi-page reads silently stop at
# page 1. Rename it to `next_page_cursor` (the `page_cursor` arg feeds it back).
# Reads from a FILE, never a pipe off `request`, so a curl failure fails the
# script (set -e) instead of being masked by jq succeeding on empty input.
rename_next_page_token() {
  jq -ce 'if has("nextPageToken") then . + {next_page_cursor: .nextPageToken} | del(.nextPageToken) else . end' "$1"
}

interval() {
  minutes=$1
  end_epoch=${2:-$(date -u +%s)}
  start_epoch=$((end_epoch - minutes * 60))
  start_time=$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)
}

case "$mode" in
  metric-query)
    metric_type=$3
    resource_filter=$4
    window_minutes=$5
    alignment_seconds=$6
    aligner=$7
    page_size=$8
    page_cursor=$9

    now_epoch=$(date -u +%s)
    end_epoch=$now_epoch
    # The provider requires identical request parameters on every page. A
    # cursor carries only the anchored time and opaque continuation, never a
    # target or filter; rebuild those from the current validated arguments.
    query_fingerprint=$(jq -nc \
      --arg endpoint "$api_base" --arg project "$project" \
      --arg metric "$metric_type" --arg filter "$resource_filter" \
      --argjson window "$window_minutes" --argjson alignment "$alignment_seconds" \
      --arg aligner "$aligner" --argjson size "$page_size" \
      '[$endpoint,$project,$metric,$filter,$window,$alignment,$aligner,$size]' | sha256sum)
    query_fingerprint=${query_fingerprint%% *}
    invalid_cursor() {
      printf '%s\n' 'Invalid Cloud Monitoring continuation; start a new query with an empty page_cursor.' >&2
      exit 2
    }
    page_token=''
    if [ -n "$page_cursor" ]; then
      # 2048 supported provider characters + 79 for v1, time and fingerprint.
      [ "${#page_cursor}" -le 2127 ] || invalid_cursor
      case "$page_cursor" in v1.*.*.*) ;; *) invalid_cursor ;; esac
      remaining=${page_cursor#v1.}
      end_epoch=${remaining%%.*}
      remaining=${remaining#*.}
      fingerprint=${remaining%%.*}
      page_token=${remaining#*.}
      case "$end_epoch" in ''|0*|*[!0-9]*) invalid_cursor ;; esac
      [ "${#end_epoch}" -le 10 ] || invalid_cursor
      [ "$end_epoch" -le "$now_epoch" ] || invalid_cursor
      [ "$end_epoch" -ge "$((window_minutes * 60))" ] || invalid_cursor
      [ "$fingerprint" = "$query_fingerprint" ] || invalid_cursor
      [ -n "$page_token" ] && [ "${#page_token}" -le 2048 ] || invalid_cursor
      case "$page_token" in *[!A-Za-z0-9+./=_~-]*) invalid_cursor ;; esac
    fi

    filter="metric.type = \"$metric_type\""
    if [ -n "$resource_filter" ]; then
      filter="$filter AND ($resource_filter)"
    fi
    interval "$window_minutes" "$end_epoch"

    set -- --get \
      --data-urlencode "filter=$filter" \
      --data-urlencode "interval.startTime=$start_time" \
      --data-urlencode "interval.endTime=$end_time" \
      --data-urlencode "view=FULL" \
      --data-urlencode "pageSize=$page_size"
    if [ "$aligner" != ALIGN_NONE ]; then
      set -- "$@" \
        --data-urlencode "aggregation.alignmentPeriod=${alignment_seconds}s" \
        --data-urlencode "aggregation.perSeriesAligner=$aligner"
    fi
    if [ -n "$page_token" ]; then
      set -- "$@" --data-urlencode "pageToken=$page_token"
    fi
    out=$(mktemp "${TMPDIR:-/tmp}/emisar-gcp-monitoring.XXXXXX")
    trap 'rm -f -- "$out"' EXIT HUP INT TERM
    request_to "$out" "$@" "$api_base/v3/projects/$project/timeSeries"
    jq -ce --arg anchor "$end_epoch" --arg fingerprint "$query_fingerprint" '
      def allowed:
        explode | all(.[];
          (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or
          (. >= 97 and . <= 122) or
          . == 43 or . == 45 or . == 46 or . == 47 or . == 61 or . == 95 or . == 126);
      if (.nextPageToken // "") == "" then del(.nextPageToken)
      elif (.nextPageToken | type) == "string" and
           (.nextPageToken | length) <= 2048 and (.nextPageToken | allowed)
      then . + {next_page_cursor: ("v1." + $anchor + "." + $fingerprint + "." + .nextPageToken)} | del(.nextPageToken)
      else error("Cloud Monitoring returned an unsupported continuation cursor")
      end' "$out"
    ;;

  metric-descriptors)
    type_prefix=$3
    active_only=$4
    page_size=$5
    page_token=$6

    set -- --get \
      --data-urlencode "activeOnly=$active_only" \
      --data-urlencode "pageSize=$page_size"
    if [ -n "$type_prefix" ]; then
      set -- "$@" --data-urlencode "filter=metric.type = starts_with(\"$type_prefix\")"
    fi
    if [ -n "$page_token" ]; then
      set -- "$@" --data-urlencode "pageToken=$page_token"
    fi
    out=$(mktemp "${TMPDIR:-/tmp}/emisar-gcp-monitoring.XXXXXX")
    trap 'rm -f -- "$out"' EXIT HUP INT TERM
    request_to "$out" "$@" "$api_base/v3/projects/$project/metricDescriptors"
    rename_next_page_token "$out"
    ;;

  alert-policy-set-enabled)
    policy=$3
    enabled=$4
    case "$enabled" in
      true|false) ;;
      *)
        printf '%s\n' "enabled must be true or false" >&2
        exit 2
        ;;
    esac
    request --request PATCH \
      --header 'Content-Type: application/json' \
      --data "{\"enabled\": $enabled}" \
      "$api_base/v3/projects/$project/alertPolicies/$policy?updateMask=enabled"
    ;;

  interconnect-utilization)
    attachment=$3
    region=$4
    window_minutes=$5
    alignment_seconds=$6
    points=$((window_minutes * 60 / alignment_seconds + 1))
    if [ "$points" -gt 1000 ]; then
      printf '%s\n' "a window of $window_minutes minutes at ${alignment_seconds}s alignment needs $points points per metric; one page holds 1000, so raise alignment_seconds or shorten the window" >&2
      exit 2
    fi
    interval "$window_minutes"
    resource_filter="resource.type = \"interconnect_attachment\" AND resource.labels.project_id = \"$project\" AND resource.labels.attachment = \"$attachment\" AND resource.labels.region = \"$region\""

    umask 077
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-gcp-monitoring.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

    # request_to rather than curl's own --output: --output takes the error body
    # too, so the operator needs the same print-then-fail guard here.
    metric_request() {
      metric=$1
      aligner=$2
      destination=$3
      request_to "$destination" --get \
        --data-urlencode "filter=metric.type = \"$metric\" AND ($resource_filter)" \
        --data-urlencode "interval.startTime=$start_time" \
        --data-urlencode "interval.endTime=$end_time" \
        --data-urlencode "aggregation.alignmentPeriod=${alignment_seconds}s" \
        --data-urlencode "aggregation.perSeriesAligner=$aligner" \
        --data-urlencode "view=FULL" \
        --data-urlencode "pageSize=1000" \
        "$api_base/v3/projects/$project/timeSeries"
    }

    metric_request \
      interconnect.googleapis.com/network/attachment/capacity \
      ALIGN_MEAN "$tmp/capacity.json"
    metric_request \
      interconnect.googleapis.com/network/attachment/received_bytes_count \
      ALIGN_RATE "$tmp/received.json"
    metric_request \
      interconnect.googleapis.com/network/attachment/sent_bytes_count \
      ALIGN_RATE "$tmp/sent.json"

    jq -nce \
      --arg project "$project" \
      --arg attachment "$attachment" \
      --arg region "$region" \
      --arg start_time "$start_time" \
      --arg end_time "$end_time" \
      --slurpfile capacity "$tmp/capacity.json" \
      --slurpfile received "$tmp/received.json" \
      --slurpfile sent "$tmp/sent.json" '
        def value:
          (.value.doubleValue // .value.int64Value // .value.floatValue) | tonumber;
        def series_points($response):
          if (($response.timeSeries // []) | length) > 1 then
            error("query returned more than one time series for the exact attachment")
          else
            [($response.timeSeries // [])[] | (.points // [])[] |
              {key: .interval.endTime, value: value}] | from_entries
          end;
        ($capacity[0] | series_points(.)) as $capacity_points |
        ($received[0] | series_points(.)) as $received_points |
        ($sent[0] | series_points(.)) as $sent_points |
        (($capacity_points + $received_points + $sent_points) | keys | unique) as $times |
        {
          project: $project,
          attachment: $attachment,
          region: $region,
          interval: {start_time: $start_time, end_time: $end_time},
          samples: [
            $times[] as $time |
            ($capacity_points[$time] // null) as $capacity |
            ($received_points[$time] // null) as $received |
            ($sent_points[$time] // null) as $sent |
            {
              end_time: $time,
              capacity_bytes_per_second: $capacity,
              received_bytes_per_second: $received,
              sent_bytes_per_second: $sent,
              ingress_utilization_ratio:
                (if $capacity != null and $capacity > 0 and $received != null
                 then $received / $capacity else null end),
              egress_utilization_ratio:
                (if $capacity != null and $capacity > 0 and $sent != null
                 then $sent / $capacity else null end)
            }
          ] | sort_by(.end_time),
          next_page_cursors: {
            capacity: ($capacity[0].nextPageToken // null),
            received: ($received[0].nextPageToken // null),
            sent: ($sent[0].nextPageToken // null)
          }
        }'
    ;;

  *)
    printf '%s\n' "unsupported Monitoring operation: $mode" >&2
    exit 2
    ;;
esac
