#!/bin/sh
set -eu

mode=$1
project=$2
access_token=$(gcloud auth print-access-token --quiet)
api_base=https://monitoring.googleapis.com

auth_config() {
  printf 'header = "Authorization: Bearer %s"\n' "$access_token"
  printf 'header = "X-Goog-User-Project: %s"\n' "$project"
}

request() {
  auth_config | curl -q --config - --fail --silent --show-error --globoff \
    --proto '=https' --connect-timeout 10 --max-time 60 \
    --max-filesize 4194304 "$@"
}

interval() {
  minutes=$1
  end_epoch=$(date -u +%s)
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
    page_token=$9

    filter="metric.type = \"$metric_type\""
    if [ -n "$resource_filter" ]; then
      filter="$filter AND ($resource_filter)"
    fi
    interval "$window_minutes"

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
    request "$@" "$api_base/v3/projects/$project/timeSeries"
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
    request "$@" "$api_base/v3/projects/$project/metricDescriptors"
    ;;

  interconnect-utilization)
    attachment=$3
    region=$4
    window_minutes=$5
    interval "$window_minutes"
    resource_filter="resource.type = \"interconnect_attachment\" AND resource.labels.attachment_name = \"$attachment\" AND resource.labels.attachment_region = \"$region\""

    umask 077
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-gcp-monitoring.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

    metric_request() {
      metric=$1
      aligner=$2
      destination=$3
      request --get \
        --data-urlencode "filter=metric.type = \"$metric\" AND ($resource_filter)" \
        --data-urlencode "interval.startTime=$start_time" \
        --data-urlencode "interval.endTime=$end_time" \
        --data-urlencode "aggregation.alignmentPeriod=60s" \
        --data-urlencode "aggregation.perSeriesAligner=$aligner" \
        --data-urlencode "view=FULL" \
        --data-urlencode "pageSize=1000" \
        --output "$destination" \
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
          next_page_tokens: {
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
