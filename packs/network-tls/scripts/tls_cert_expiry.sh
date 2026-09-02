#!/bin/sh
# Keep connection and certificate parsing as separate guarded stages so an
# unreachable or plaintext endpoint reports its real TLS diagnostic instead of
# a misleading "could not read certificate" from the downstream parser.
set -eu

host=$1
port=$2
sni=$3
[ -n "$sni" ] || sni=$host

tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-tls-expiry.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

if openssl s_client -connect "$host:$port" -servername "$sni" </dev/null \
	>"$tmp/handshake" 2>"$tmp/handshake.err"; then
	:
else
	status=$?
	printf 'TLS connection to %s:%s failed\n' "$host" "$port" >&2
	tail -c 4096 "$tmp/handshake.err" >&2
	exit "$status"
fi

if openssl x509 -noout -dates -subject -issuer <"$tmp/handshake" \
	>"$tmp/certificate" 2>"$tmp/certificate.err"; then
	cat "$tmp/certificate"
else
	status=$?
	printf 'TLS handshake with %s:%s returned no readable certificate\n' "$host" "$port" >&2
	tail -c 3072 "$tmp/handshake.err" >&2
	tail -c 1024 "$tmp/certificate.err" >&2
	exit "$status"
fi
