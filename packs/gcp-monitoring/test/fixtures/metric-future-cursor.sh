#!/bin/sh
set -eu
cursor=$(/bin/sh /packs/gcp-monitoring/test/fixtures/metric-first-page.sh "$@")
remaining=${cursor#v1.}
printf 'v1.9999999999.%s\n' "${remaining#*.}"
