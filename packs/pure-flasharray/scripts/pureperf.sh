#!/bin/sh
# Perform one bounded performance read and retain only the documented response
# envelope. Samples are operational telemetry; authentication headers remain
# inside pureget.sh and never enter this output.
#
#   pureperf.sh <collection> <window> <resolution> [limit] [names]
#
# The array samples performance continuously, so a window asks for history
# instead of the latest sample. An item is one object at one sample time, so a
# window trades objects per page for samples per object; an auto resolution
# keeps that trade sane and an explicit resolution overrides it.
set -eu

# The array-wide endpoint reads one object, so its page size is fixed here
# rather than exposed as an argument.
arrays_limit=1000

collection=$1
window=$2
resolution=$3
limit=${4:-$arrays_limit}
names=${5:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "$collection" in
	arrays)
		path=/arrays/performance
		;;
	volumes)
		path=/volumes/performance
		;;
	hosts)
		path=/hosts/performance
		;;
	network-interfaces)
		path=/network-interfaces/performance
		;;
	*)
		echo "pure-flasharray: invalid performance collection" >&2
		exit 2
		;;
esac

# Milliseconds between samples. The array accepts only these intervals; each
# action's enum offers the ones its own endpoint supports.
case "$resolution" in
	auto) resolution_ms="" ;;
	1s) resolution_ms=1000 ;;
	30s) resolution_ms=30000 ;;
	5m) resolution_ms=300000 ;;
	30m) resolution_ms=1800000 ;;
	2h) resolution_ms=7200000 ;;
	8h) resolution_ms=28800000 ;;
	24h) resolution_ms=86400000 ;;
	*)
		echo "pure-flasharray: invalid resolution" >&2
		exit 2
		;;
esac

case "$window" in
	latest)
		window_seconds=""
		auto_ms=""
		;;
	5m)
		window_seconds=300
		auto_ms=30000
		;;
	1h)
		window_seconds=3600
		auto_ms=300000
		;;
	6h)
		window_seconds=21600
		auto_ms=1800000
		;;
	24h)
		window_seconds=86400
		auto_ms=7200000
		;;
	7d)
		window_seconds=604800
		auto_ms=28800000
		;;
	*)
		echo "pure-flasharray: invalid window" >&2
		exit 2
		;;
esac

set -- --data-urlencode "limit=$limit"
if [ -n "$names" ]; then
	set -- "$@" --data-urlencode "names=$names"
fi
if [ -n "$window_seconds" ]; then
	if [ -z "$resolution_ms" ]; then
		resolution_ms=$auto_ms
	fi
	# The array fills a page sample-time by sample-time, so a series longer than
	# the page returns the first moments of the window for every object — an
	# answer that looks like the whole window but is not.
	if [ $((window_seconds * 1000 / resolution_ms)) -gt "$limit" ]; then
		echo "pure-flasharray: $window at $resolution resolution needs more than $limit samples per object — widen the resolution, shorten the window, or raise the limit" >&2
		exit 2
	fi
	end_ms=$(($(date +%s) * 1000))
	set -- "$@" \
		--data-urlencode "start_time=$((end_ms - window_seconds * 1000))" \
		--data-urlencode "end_time=$end_ms"
fi
if [ -n "$resolution_ms" ]; then
	set -- "$@" --data-urlencode "resolution=$resolution_ms"
fi

response=$(mktemp)
trap 'rm -f "$response"' EXIT HUP INT TERM
if sh "$script_dir/pureget.sh" "$path" "$@" >"$response"; then
	# These endpoints answer a full page without reporting that more remains and
	# without a continuation token, so a full page is reported as truncated here
	# rather than passed off as the complete answer.
	jq -e --argjson limit "$limit" '{
		items: (.items // []),
		more_items_remaining: (((.items // []) | length) >= $limit),
		total_item_count: (.total_item_count // null),
		errors: (.errors // [])
	}' "$response"
else
	status=$?
	exit "$status"
fi
