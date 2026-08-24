#!/bin/sh
# vmget.sh — packaged with the "victoriametrics" emisar pack. emisar loads
# it from disk when the pack is trusted, journals its SHA-256 with every
# run, and executes it via the interpreter named in each action. It is
# never fetched or assembled at request time.
#
# Read-only GET against the VictoriaMetrics / Prometheus-compatible query
# API. Arguments:
#
#   $1...  normally the path appended to $VM_URL followed by extra curl flags.
#          vm.query_range instead prefixes --bounded-range, window, and step;
#          the helper validates that pair before reading credentials or running
#          curl, then consumes the same path-and-flags shape as every other action.
#          $VM_URL already carries any /prometheus or
#          /select/<accountID>/prometheus prefix, so this one helper serves
#          single-node, cluster, and vmauth-fronted endpoints unchanged.
#          Values are rendered into argv by the cloud-validated template engine
#          and URL-encoded by curl; they never enter a shell string.
#
# When $VM_BEARER_TOKEN is set it is streamed to curl over stdin (-H @-),
# so the token never appears in argv, a `ps` listing, or the audit log.
#
# VM_URL defaults to a local single-node VictoriaMetrics; override it for a
# cluster (vmselect) or a remote / vmauth-fronted endpoint.
set -eu

VM_URL=${VM_URL:-http://127.0.0.1:8428}

duration_seconds() {
	case "$1" in
	*s) value=${1%s}; multiplier=1 ;;
	*m) value=${1%m}; multiplier=60 ;;
	*h) value=${1%h}; multiplier=3600 ;;
	*d) value=${1%d}; multiplier=86400 ;;
	*w) value=${1%w}; multiplier=604800 ;;
	*y) value=${1%y}; multiplier=31536000 ;;
	*) return 1 ;;
	esac
	case "$value" in
	"" | 0* | *[!0-9]* | ??????*) return 1 ;;
	esac
	printf '%s\n' "$((value * multiplier))"
}

if [ "${1:-}" = "--bounded-range" ]; then
	window=${2:-}
	step=${3:-}
	shift 3

	if ! window_seconds=$(duration_seconds "$window"); then
		echo "victoriametrics: invalid window $window" >&2
		exit 1
	fi
	if ! step_seconds=$(duration_seconds "$step"); then
		echo "victoriametrics: invalid step $step" >&2
		exit 1
	fi
	if [ "$window_seconds" -gt 604800 ]; then
		echo "victoriametrics: window $window exceeds the 7d maximum" >&2
		exit 1
	fi

	points=$((window_seconds / step_seconds + 1))
	if [ "$points" -gt 10081 ]; then
		echo "victoriametrics: window $window at step $step produces $points evaluation timestamps; maximum is 10081" >&2
		exit 1
	fi
fi

path=$1
shift

if [ -n "${VM_BEARER_TOKEN:-}" ]; then
	printf 'Authorization: Bearer %s\n' "$VM_BEARER_TOKEN" | curl --globoff --proto '=http,https' -fsS -G -H @- "$@" "$VM_URL$path"
else
	curl --globoff --proto '=http,https' -fsS -G "$@" "$VM_URL$path"
fi
