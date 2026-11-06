#!/bin/sh
set -eu
printf '%s\n' 1700000000 >/tmp/gcp-logging-clock
/bin/sh /packs/gcp-monitoring/scripts/monitoring_api.sh metric-query "$@" '' >/tmp/gcp-metric-first-page.json
# Advance deterministically: a continuation must reuse the first interval.
printf '%s\n' 1700000120 >/tmp/gcp-logging-clock
jq -er .next_page_cursor /tmp/gcp-metric-first-page.json
