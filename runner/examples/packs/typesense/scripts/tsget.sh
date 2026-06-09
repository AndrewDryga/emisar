#!/bin/sh
# tsget.sh — packaged with the "typesense" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via the interpreter named in each action. It is never fetched or
# assembled at request time.
#
# One read-only GET against the Typesense API. $1 is the path appended to
# $TYPESENSE_URL (e.g. /collections); $2... are extra curl flags. The admin
# API key is read from $TYPESENSE_API_KEY and streamed to curl as the
# X-TYPESENSE-API-KEY header over stdin (-H @-), so it never lands in argv, a
# `ps` listing, or the audit log. $TYPESENSE_URL defaults to a local node.
TYPESENSE_URL=${TYPESENSE_URL:-http://127.0.0.1:8108}
path=$1
shift
if [ -n "${TYPESENSE_API_KEY:-}" ]; then
	printf 'X-TYPESENSE-API-KEY: %s\n' "$TYPESENSE_API_KEY" | curl -sS -H @- "$@" "$TYPESENSE_URL$path"
else
	curl -sS "$@" "$TYPESENSE_URL$path"
fi
