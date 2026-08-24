#!/bin/sh
set -eu

query_request=false
cost_canary=false
start=
extra_window=
end=false
timeout=false

for argument in "$@"; do
	case "$argument" in
	http://cost-canary/select/logsql/*) query_request=true; cost_canary=true ;;
	*/select/logsql/*) query_request=true ;;
	start=*) start=${argument#start=} ;;
	end=now) end=true ;;
	extra_filters=_time:*) extra_window=${argument#extra_filters=_time:} ;;
	timeout=30s) timeout=true ;;
	esac
done

if [ "$query_request" = true ] &&
	{ [ -z "$start" ] || [ "$start" != "$extra_window" ] || [ "$end" != true ] || [ "$timeout" != true ]; }; then
	printf 'PACKTEST_VL_MISSING_BOUND %s\n' "$*" >&2
	: >/tmp/packtest-victorialogs-missing-bound
	exit 96
fi

if [ "$cost_canary" = true ]; then
	printf '%s\n' "$*" >/tmp/packtest-victorialogs-cost-argv
	printf '{"PACKTEST_VL_COST_CANARY":true}\n'
	exit 0
fi

exec /usr/bin/curl "$@"
