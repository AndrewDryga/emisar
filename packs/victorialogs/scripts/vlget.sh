#!/bin/sh
# vlget.sh — packaged with the "victorialogs" emisar pack. emisar loads it
# from disk when the pack is trusted, journals its SHA-256 with every run,
# and runs it via the interpreter named in each action. It is never fetched
# or assembled at request time.
#
# Read-only GET against the VictoriaLogs LogsQL HTTP API.
#
#   $1     bounded trailing window.
#   $2     step for bucketed endpoints, or - for endpoints without one.
#   $3     path appended to $VL_URL, e.g. /select/logsql/query.
#   $4...  extra curl flags — normally --data-urlencode "name=value" pairs.
#          Values are rendered into argv by the cloud-validated template
#          engine and URL-encoded by curl; they never enter a shell string.
#
# Optional request headers, streamed to curl over stdin (-H @-) so a token
# never lands in argv, a `ps` listing, or the audit log:
#
#   VL_BEARER_TOKEN  ->  Authorization: Bearer <token>   (vmauth front)
#   VL_ACCOUNT_ID    ->  AccountID: <id>                 (tenant; default 0)
#   VL_PROJECT_ID    ->  ProjectID: <id>                 (tenant; default 0)
#
# VL_URL defaults to a local single-node VictoriaLogs; override it for a
# remote or vmauth-fronted endpoint.
set -eu

VL_URL=${VL_URL:-http://127.0.0.1:9428}

duration_seconds() {
	case "$1" in
	*s) value=${1%s}; multiplier=1 ;;
	*m) value=${1%m}; multiplier=60 ;;
	*h) value=${1%h}; multiplier=3600 ;;
	*d) value=${1%d}; multiplier=86400 ;;
	*w) value=${1%w}; multiplier=604800 ;;
	*) return 1 ;;
	esac
	case "$value" in
	"" | 0* | *[!0-9]* | ??????*) return 1 ;;
	esac
	printf '%s\n' "$((value * multiplier))"
}

window=$1
step=$2
shift 2

if ! window_seconds=$(duration_seconds "$window"); then
	echo "victorialogs: invalid window $window" >&2
	exit 1
fi
if [ "$window_seconds" -gt 86400 ]; then
	echo "victorialogs: window $window exceeds the 24h maximum" >&2
	exit 1
fi
if [ "$step" != "-" ]; then
	if ! step_seconds=$(duration_seconds "$step"); then
		echo "victorialogs: invalid step $step" >&2
		exit 1
	fi
	points=$((window_seconds / step_seconds + 1))
	if [ "$points" -gt 10081 ]; then
		echo "victorialogs: window $window at step $step produces $points buckets; maximum is 10081" >&2
		exit 1
	fi
fi

path=$1
shift

set -- \
	--data-urlencode "start=$window" \
	--data-urlencode "end=now" \
	--data-urlencode "extra_filters=_time:$window" \
	--data-urlencode "timeout=30s" \
	"$@"

if [ -n "${VL_BEARER_TOKEN:-}${VL_ACCOUNT_ID:-}${VL_PROJECT_ID:-}" ]; then
	{
		[ -n "${VL_BEARER_TOKEN:-}" ] && printf 'Authorization: Bearer %s\n' "$VL_BEARER_TOKEN"
		[ -n "${VL_ACCOUNT_ID:-}" ] && printf 'AccountID: %s\n' "$VL_ACCOUNT_ID"
		[ -n "${VL_PROJECT_ID:-}" ] && printf 'ProjectID: %s\n' "$VL_PROJECT_ID"
	} | curl --globoff --proto '=http,https' -fsS -G -H @- "$@" "$VL_URL$path"
else
	curl --globoff --proto '=http,https' -fsS -G "$@" "$VL_URL$path"
fi
