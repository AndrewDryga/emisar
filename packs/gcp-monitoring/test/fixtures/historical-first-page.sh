#!/bin/sh
set -eu
/bin/sh /packs/gcp-monitoring/scripts/logging_api.sh log-entries example-prod DEFAULT gce_instance '' 60 5 '' '' '' "$1" "$2" "$3" | jq -er .next_page_cursor
