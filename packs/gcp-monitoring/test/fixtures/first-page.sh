#!/bin/sh
set -eu
printf '%s\n' 1700000000 >/tmp/gcp-logging-clock
/bin/sh /packs/gcp-monitoring/scripts/logging_api.sh log-entries "$@" '' >/tmp/gcp-logging-first-page.json
# No sleep or wall-clock race: the second real action sees two minutes later.
printf '%s\n' 1700000120 >/tmp/gcp-logging-clock
jq -er .next_page_cursor /tmp/gcp-logging-first-page.json
