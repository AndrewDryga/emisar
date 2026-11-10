#!/bin/sh
set -eu
/bin/sh /packs/gcp-monitoring/scripts/logging_api.sh log-entry-detail "$1" "$2" "$3" "$4" "$5" '' | jq -er .next_page_cursor
