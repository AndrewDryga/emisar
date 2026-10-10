#!/bin/sh
# http_services_summary.sh — packaged with the "traefik" emisar pack. emisar
# loads it from disk when the pack is trusted, journals its SHA-256 with every
# run, and runs it via /bin/sh. It is never fetched or assembled at request time.
#
# The raw /api/http/services dump is correct but too large to parse in a preflight
# (the full load-balancer config of every service, up to 4 MiB). This does one
# read-only GET and a pure-jq reshape into a compact, name-sorted array — one
# row per service with its status, error count/list, backend up/down/total, and
# the URLs of only the DOWN backends. Full server URLs are kept only where they
# matter (a failing backend), never the whole healthy load-balancer config.
#
#   $1   only_unhealthy ("true"/"false"): when "true", keep only services that
#        are not "enabled", carry errors, have a DOWN backend, or are a
#        load-balancer with no UP backend. Bounded to a boolean by the schema.
#
# URL/auth handling mirrors trget.sh: $TRAEFIK_URL (default :8080 api.insecure),
# optional TRAEFIK_BASICAUTH (base64'd over stdin, never in argv), and
# TRAEFIK_INSECURE=true to skip TLS verify on a self-signed API.
set -eu
TRAEFIK_URL=${TRAEFIK_URL:-http://127.0.0.1:8080}
K=""
[ "${TRAEFIK_INSECURE:-}" = "true" ] && K="-k"
only_unhealthy=$1

# Byte-identical to host_readiness.sh's get() and to trget.sh's request; each
# pack file is content-hashed on its own, so a sourced helper cannot be shared.
# Keep the three in step — the capture below is the difference that matters.
get() {
	request_path=$1
	shift
	if [ -n "${TRAEFIK_BASICAUTH:-}" ]; then
		printf 'Authorization: Basic %s\n' "$(printf '%s' "$TRAEFIK_BASICAUTH" | base64 | tr -d '\n')" |
			curl -q --globoff --proto '=http,https' -fsS $K -H @- "$@" "$TRAEFIK_URL$request_path"
	else
		curl -q --globoff --proto '=http,https' -fsS $K "$@" "$TRAEFIK_URL$request_path"
	fi
}

# Fixed bulk query avoids Traefik's default 100-row page. Bound input before
# parsing, including bodies without Content-Length, and check the producer
# independently of head. Keep this helper in step with trget and readiness.
inventory_get() (
	umask 077
	work=$(mktemp -d "${TMPDIR:-/tmp}/emisar-traefik.XXXXXXXX") || exit 1
	trap 'rm -f -- "$work/body" "$work/status"; rmdir -- "$work"' 0
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	{
		rc=0
		get "$@" --get --data-urlencode page=1 --data-urlencode per_page=2147483647 || rc=$?
		printf '%s\n' "$rc" >"$work/status" || exit 1
	} | head -c 4194305 >"$work/body" || exit 1
	bytes=$(wc -c <"$work/body") || exit 1
	[ "$bytes" -le 4194304 ] || { printf '%s\n' 'Traefik inventory exceeded 4 MiB' >&2; exit 1; }
	rc=$(cat "$work/status") || exit 1
	case "$rc" in ''|*[!0-9]*) exit 1 ;; esac
	[ "$rc" -eq 0 ] || exit "$rc"
	jq -jecs 'if length == 1 and (.[0] | type) == "array" then .[0]
	  else error("Traefik API returned an invalid JSON array") end' "$work/body"
)

# Captured, not piped: a pipeline exits with jq's status, and jq exits 0 on
# empty stdin — so an API that is down, 401-ing, or on another port answered
# "[]", read as "every service is healthy" during the cutover preflight this
# action exists for. Under `set -e` the substitution fails the action instead.
# This is the shape host_readiness.sh already uses for the same two GETs.
services=$(inventory_get /api/http/services)

# serverStatus is the health-check map; when absent (no health check) the
# configured backends count as UP. "unhealthy" is computed only to drive the
# only_unhealthy filter, then dropped — the up==0 leg fires only for an actual
# load-balancer (an internal/weighted service legitimately has no backends).
printf '%s' "$services" | jq -c --arg only "$only_unhealthy" '
	map(
	  (.loadBalancer != null) as $has_lb
	  | (.loadBalancer.servers // []) as $servers
	  | (.serverStatus // {}) as $ss
	  | ($servers | length) as $total
	  | (if ($ss | length) > 0
	       then ([$ss | to_entries[] | select(.value == "UP")] | length)
	       else $total end) as $up
	  | (if ($ss | length) > 0
	       then ([$ss | to_entries[] | select(.value == "DOWN")] | length)
	       else 0 end) as $down
	  | {
	      name, provider, status,
	      error_count: ((.error // []) | length),
	      errors: (.error // []),
	      servers: {up: $up, down: $down, total: $total},
	      down_servers: [$ss | to_entries[] | select(.value == "DOWN") | .key],
	      unhealthy: (.status != "enabled"
	                  or ((.error // []) | length) > 0
	                  or $down > 0
	                  or ($has_lb and $up == 0))
	    }
	)
	| (if $only == "true" then map(select(.unhealthy)) else . end)
	| map(del(.unhealthy))
	| sort_by(.name)'
