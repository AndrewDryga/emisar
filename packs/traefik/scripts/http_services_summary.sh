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

get() {
	if [ -n "${TRAEFIK_BASICAUTH:-}" ]; then
		printf 'Authorization: Basic %s\n' "$(printf '%s' "$TRAEFIK_BASICAUTH" | base64 | tr -d '\n')" |
			curl -sS $K -H @- "$TRAEFIK_URL$1"
	else
		curl -sS $K "$TRAEFIK_URL$1"
	fi
}

# serverStatus is the health-check map; when absent (no health check) the
# configured backends count as UP. "unhealthy" is computed only to drive the
# only_unhealthy filter, then dropped — the up==0 leg fires only for an actual
# load-balancer (an internal/weighted service legitimately has no backends).
get /api/http/services | jq -c --arg only "$only_unhealthy" '
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
