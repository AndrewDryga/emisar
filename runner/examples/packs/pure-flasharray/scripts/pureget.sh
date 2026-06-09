#!/bin/sh
# pureget.sh — packaged with the "pure-flasharray" emisar pack. emisar loads
# it from disk when the pack is trusted, journals its SHA-256 with every run,
# and runs it via the interpreter named in each action. It is never fetched
# or assembled at request time.
#
# One read-only GET against the Pure Storage FlashArray REST API 2.x. The
# array uses a two-step auth: an API token is exchanged for a short-lived
# session token. Arguments:
#
#   $1     resource path under /api/<version>, e.g. /connections.
#   $2...  extra curl flags from the action — e.g.
#          --data-urlencode "filter=state='open'" (added as query params by
#          the -G below). Values are rendered into argv by the cloud-validated
#          template engine and never enter a shell string.
#
# $PURE_URL is the array management endpoint (defaults to a common VIP). The
# API token is read from $PURE_API_TOKEN and sent as the `api-token` header
# over stdin (-H @-); the returned `x-auth-token` session token is likewise
# streamed over stdin on the read call. Neither token ever lands in argv, a
# `ps` listing, or the audit log. FlashArrays ship a self-signed certificate,
# so set PURE_INSECURE=true to skip TLS verification.
PURE_URL=${PURE_URL:-https://192.168.1.1}
K=""
[ "${PURE_INSECURE:-}" = "true" ] && K="-k"
path=$1
shift

# Negotiate the highest REST 2.x version the array supports (no auth needed).
ver=$(curl -sS $K "$PURE_URL/api/api_version" | grep -oE '2\.[0-9]+' | sort -t. -k2 -n | tail -1)
[ -n "$ver" ] || ver=2.2

# Exchange the API token for a session token (api-token in -> x-auth-token out).
sess=$(printf 'api-token: %s\n' "${PURE_API_TOKEN:-}" |
	curl -sS $K -D - -o /dev/null -X POST -H @- "$PURE_URL/api/$ver/login" |
	tr -d '\r' | awk -F': ' 'tolower($1)=="x-auth-token"{print $2}')

# Read call — session token over stdin; -G folds any --data-urlencode into the query.
printf 'x-auth-token: %s\n' "$sess" | curl -sS $K -G -H @- "$@" "$PURE_URL/api/$ver$path"
