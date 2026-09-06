#!/bin/sh
# Bounded CloudWatch statistics read. The action schema owns the argument
# shapes; this script enforces CloudWatch's own rules before the call so the
# agent gets a plain message instead of an API error: one response holds at
# most 1440 data points, periods are minute multiples, and older data exists
# only at coarser periods (5 minutes past 15 days, 1 hour past 63 days).
set -eu

namespace=$1
metric=$2
window_minutes=$3
period=$4
dimensions=${5:-}

if [ $((period % 60)) -ne 0 ]; then
	echo "cloudwatch: period must be a multiple of 60 seconds" >&2
	exit 2
fi
window_seconds=$((window_minutes * 60))
points=$((window_seconds / period))
if [ "$points" -gt 1440 ]; then
	echo "cloudwatch: $window_minutes minutes at a ${period}s period is $points data points; one call returns at most 1440, so raise period or shorten the window" >&2
	exit 2
fi
if [ "$window_minutes" -gt 90720 ] && [ $((period % 3600)) -ne 0 ]; then
	echo "cloudwatch: data older than 63 days exists only at periods that are multiples of 3600 seconds" >&2
	exit 2
fi
if [ "$window_minutes" -gt 21600 ] && [ $((period % 300)) -ne 0 ]; then
	echo "cloudwatch: data older than 15 days exists only at periods that are multiples of 300 seconds" >&2
	exit 2
fi

end_epoch=$(date -u +%s)
end=$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)
start=$(date -u -d "@$((end_epoch - window_seconds))" +%Y-%m-%dT%H:%M:%SZ)

set -- aws cloudwatch get-metric-statistics \
	--namespace "$namespace" --metric-name "$metric" \
	--start-time "$start" --end-time "$end" --period "$period" \
	--statistics Average Maximum --output json
if [ -n "$dimensions" ]; then
	# The schema admits only Name=...,Value=... pairs separated by single
	# spaces, with no glob or shell characters, so word splitting here yields
	# exactly those pairs as separate CLI list elements.
	# shellcheck disable=SC2086
	set -- "$@" --dimensions $dimensions
fi
exec "$@"
