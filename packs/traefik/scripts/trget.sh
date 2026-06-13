#!/bin/sh
# trget.sh — packaged with the "traefik" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and
# runs it via the interpreter named in each action. It is never fetched or
# assembled at request time.
#
# One read-only GET against the Traefik HTTP API. The OSS API is GET-only —
# it never mutates config — so this helper only ever reads. Arguments:
#
#   $1     path appended to $TRAEFIK_URL, e.g. /api/http/routers.
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
TRAEFIK_URL=${TRAEFIK_URL:-http://127.0.0.1:8080}
K=""
[ "${TRAEFIK_INSECURE:-}" = "true" ] && K="-k"
path=$1
shift

if [ -n "${TRAEFIK_BASICAUTH:-}" ]; then
	printf 'Authorization: Basic %s\n' "$(printf '%s' "$TRAEFIK_BASICAUTH" | base64 | tr -d '\n')" |
		curl -sS $K -H @- "$@" "$TRAEFIK_URL$path"
else
	curl -sS $K "$@" "$TRAEFIK_URL$path"
fi
