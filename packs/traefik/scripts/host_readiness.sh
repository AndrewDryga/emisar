#!/bin/sh
# host_readiness.sh — packaged with the "traefik" emisar pack. emisar loads it
# from disk when the pack is trusted, journals its SHA-256 with every run, and
# runs it via /bin/sh. It is never fetched or assembled at request time.
#
# Answers the one question a cutover preflight actually asks: "is this public
# host live behind Traefik right now?" — not "does a service exist somewhere in
# Consul." It does two read-only GETs (/api/http/routers + /api/http/services)
# and a pure-jq join, emitting ONE compact verdict: is there an enabled router
# for the host, a healthy service behind it, and at least one UP backend?
#
#   $1   the public host to check, e.g. app.va1.example.com. Bounded by the
#        action schema to an anchored hostname (no shell metacharacters), and
#        passed to jq as --arg — it never enters a command string.
#
# URL/auth handling mirrors trget.sh: $TRAEFIK_URL (default :8080 api.insecure),
# optional TRAEFIK_BASICAUTH (base64'd over stdin, never in argv), and
# TRAEFIK_INSECURE=true to skip TLS verify on a self-signed API. set -e makes a
# failed fetch abort loudly rather than emit a verdict from partial data.
set -eu
TRAEFIK_URL=${TRAEFIK_URL:-http://127.0.0.1:8080}
K=""
[ "${TRAEFIK_INSECURE:-}" = "true" ] && K="-k"
host=$1

get() {
	if [ -n "${TRAEFIK_BASICAUTH:-}" ]; then
		printf 'Authorization: Basic %s\n' "$(printf '%s' "$TRAEFIK_BASICAUTH" | base64 | tr -d '\n')" |
			curl -sS $K -H @- "$TRAEFIK_URL$1"
	else
		curl -sS $K "$TRAEFIK_URL$1"
	fi
}

routers=$(get /api/http/routers)
services=$(get /api/http/services)

# Pure jq join. A router matches the host when its rule contains Host(`<host>`)
# (Traefik always backtick-wraps the value, so the wrap makes the match exact —
# "example.com" never matches "notexample.com"). The router's service ref is
# resolved to its full "<name>@<provider>" form: a bare ref inherits the
# router's own provider, an already-suffixed ref (@file, @consulcatalog, …) is
# kept as-is. serverStatus is the health-check map; when it is absent (no health
# check configured) the configured backends are treated as UP. ready ⇔ no
# failures — an operator who tolerates a degraded backend reads failures[].
printf '%s' "$services" | jq -c \
	--arg host "$host" \
	--argjson routers "$routers" '
	(map({key: .name, value: .}) | from_entries) as $svcByName
	| ($routers
	   | map(select(.rule != null and (.rule | contains("`" + $host + "`"))))) as $matched
	| (($matched | map(select(.status == "enabled")) | .[0]) // $matched[0]) as $r
	| (if $r == null then null
	   elif (($r.service // "") | contains("@")) then $r.service
	   else ($r.service // "") + "@" + ($r.provider // "") end) as $svcName
	| (if $svcName == null then null else $svcByName[$svcName] end) as $s
	| ($s.loadBalancer.servers // []) as $servers
	| ($s.serverStatus // {}) as $sstatus
	| ($servers | length) as $total
	| (if ($sstatus | length) > 0
	     then ([$sstatus | to_entries[] | select(.value == "UP")] | length)
	     else $total end) as $up
	| (if ($sstatus | length) > 0
	     then ([$sstatus | to_entries[] | select(.value == "DOWN")] | length)
	     else 0 end) as $down
	| ([$sstatus | to_entries[] | select(.value == "DOWN") | .key]) as $down_urls
	| (
	    (if $r == null then ["missing_router"] else [] end)
	    + (if $r != null and $r.status != "enabled" then ["router_not_enabled"] else [] end)
	    + (if $r != null and (($r.error // []) | length) > 0 then ["router_errors"] else [] end)
	    + (if $r != null and $s == null then ["missing_service"] else [] end)
	    + (if $s != null and $s.status != "enabled" then ["service_not_enabled"] else [] end)
	    + (if $s != null and (($s.error // []) | length) > 0 then ["service_errors"] else [] end)
	    + (if $s != null and $up == 0 then ["no_up_backends"] else [] end)
	    + (if $s != null and $up > 0 and $down > 0 then ["backend_down"] else [] end)
	  ) as $failures
	| {
	    host: $host,
	    ready: (($failures | length) == 0),
	    router: (if $r == null then null else {
	      name: $r.name, provider: $r.provider, rule: $r.rule,
	      status: $r.status, errors: ($r.error // [])
	    } end),
	    service: (if $s == null then null else {
	      name: $s.name, provider: $s.provider,
	      status: $s.status, errors: ($s.error // [])
	    } end),
	    backends: {up: $up, down: $down, total: $total, down_urls: $down_urls},
	    failures: $failures
	  }'
