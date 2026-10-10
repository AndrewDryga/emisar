#!/bin/sh
set -eu
curl -fsS --cacert /packs/gcp-monitoring/test/fixtures/server.crt https://gcp-api:8443/probe/state |
  jq -e --arg minutes "$1" --arg alignment "$2" '
    .requests | length == 3 and
    ([.[].filter | split("\"")[1]] | sort) == ([
      "interconnect.googleapis.com/network/attachment/capacity",
      "interconnect.googleapis.com/network/attachment/received_bytes_count",
      "interconnect.googleapis.com/network/attachment/sent_bytes_count"] | sort) and
    ([.[]."interval.startTime"] | unique | length) == 1 and
    ([.[]."interval.endTime"] | unique | length) == 1 and
    all(.[];
      .filter | contains("resource.type = \"interconnect_attachment\"") and
        contains("resource.labels.project_id = \"example-prod\"") and
        contains("resource.labels.attachment = \"harness-attachment\"") and
        contains("resource.labels.region = \"us-central1\"") and
        (contains("attachment_name") | not) and (contains("attachment_region") | not)) and
    all(.[];
      .interval_minutes == ($minutes|tonumber) and
      ."aggregation.alignmentPeriod" == ($alignment + "s") and
      .view == "FULL" and .pageSize == "1000" and
      ."aggregation.perSeriesAligner" ==
        (if .filter | contains("/capacity\"") then "ALIGN_MEAN" else "ALIGN_RATE" end))
  '
