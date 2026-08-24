#!/bin/sh
# Bounded Prometheus range query. The action schema owns duration syntax; this
# script enforces the relationship between the otherwise-valid window and step
# before curl can ask the backend to evaluate it.
set -eu

query=$1
window=$2
step=$3

duration_seconds() {
	case "$1" in
	*s) value=${1%s}; multiplier=1 ;;
	*m) value=${1%m}; multiplier=60 ;;
	*h) value=${1%h}; multiplier=3600 ;;
	*d) value=${1%d}; multiplier=86400 ;;
	*) return 1 ;;
	esac
	case "$value" in
	"" | 0* | *[!0-9]* | ??????*) return 1 ;;
	esac
	printf '%s\n' "$((value * multiplier))"
}

if ! window_seconds=$(duration_seconds "$window"); then
	echo "prometheus: invalid window $window" >&2
	exit 1
fi
if ! step_seconds=$(duration_seconds "$step"); then
	echo "prometheus: invalid step $step" >&2
	exit 1
fi

if [ "$window_seconds" -gt 604800 ]; then
	echo "prometheus: window $window exceeds the 7d maximum" >&2
	exit 1
fi

points=$((window_seconds / step_seconds + 1))
if [ "$points" -gt 10081 ]; then
	echo "prometheus: window $window at step $step produces $points evaluation timestamps; maximum is 10081" >&2
	exit 1
fi

end=$(date -u +%s)
start=$((end - window_seconds))
curl -fsS --globoff --proto '=http,https' -G \
	--data-urlencode "query=$query" \
	--data-urlencode "start=$start" \
	--data-urlencode "end=$end" \
	--data-urlencode "step=$step" \
	--data-urlencode "timeout=30s" \
	"${PROM_URL:-http://127.0.0.1:9090}/api/v1/query_range"
