#!/bin/sh
# trget.sh — packaged with the "traefik" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and
# runs it via the interpreter named in each action. It is never fetched or
# assembled at request time.
#
# One read-only GET against the Traefik HTTP API. The OSS API is GET-only —
# it never mutates config — so this helper only ever reads. Arguments:
#
#   $1     path appended to $TRAEFIK_URL, e.g. /api/http/routers. /ping
#          uses $TRAEFIK_PING_URL when set because production deployments often
#          keep liveness on a separate entrypoint from the API. /metrics
#          similarly uses $TRAEFIK_METRICS_URL when set.
#   $2...  extra curl flags from the action (rarely needed; e.g.
#          --get --data-urlencode for paged endpoints). Values are rendered
#          into argv by the cloud-validated template engine and never enter
#          a shell string.
#
# $TRAEFIK_URL defaults to the dashboard/api entrypoint on localhost
# (api.insecure mode, :8080). For a production API behind a basicAuth
# middleware, set TRAEFIK_BASICAUTH=user:password — it is base64-encoded and
# streamed to curl as an Authorization header over stdin (-H @-), so it never
# lands in argv, a `ps` listing, or the audit log. Set TRAEFIK_INSECURE=true
# to skip TLS verification when the API is served over https with a
# self-signed certificate.
#
# The curl invocation below is byte-identical to the get() helpers in
# host_readiness.sh and http_services_summary.sh; each pack file is
# content-hashed on its own, so a sourced helper cannot be shared. Keep the
# three in step.
set -eu

TRAEFIK_URL=${TRAEFIK_URL:-http://127.0.0.1:8080}
K=""
if [ "${TRAEFIK_INSECURE:-}" = "true" ]; then
	K="-k"
fi
path=$1
shift

base_url=$TRAEFIK_URL
case "$path" in
	/ping) base_url=${TRAEFIK_PING_URL:-$TRAEFIK_URL} ;;
	/metrics) base_url=${TRAEFIK_METRICS_URL:-$TRAEFIK_URL} ;;
esac

get() {
	request_path=$1
	shift
	if [ -n "${TRAEFIK_BASICAUTH:-}" ]; then
		printf 'Authorization: Basic %s\n' "$(printf '%s' "$TRAEFIK_BASICAUTH" | base64 | tr -d '\n')" |
			curl -q --globoff --proto '=http,https' -fsS $K -H @- "$@" "$base_url$request_path"
	else
		curl -q --globoff --proto '=http,https' -fsS $K "$@" "$base_url$request_path"
	fi
}

# Fixed bulk query avoids Traefik's default 100-row page. Bound input before
# parsing, including bodies without Content-Length, and check the producer
# independently of head. Keep this helper in step with both projections.
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

case "$path" in
	/api/http/services|/api/http/routers) inventory_get "$path" "$@" ;;
	*) get "$path" "$@" ;;
esac
