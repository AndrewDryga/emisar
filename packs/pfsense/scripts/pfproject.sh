#!/bin/sh
# pfproject.sh — packaged with the "pfsense" emisar pack; emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via /bin/sh. Never fetched or assembled at request time.
#
# One projected read, for the endpoints whose response carries a secret beside
# the facts an operator wants: a certificate's `prv` PEM, an NTP peer's
# authentication key, a WireGuard peer's pre-shared key, a resolver's free-text
# custom options. To make a leak structurally impossible, this does NOT pass the
# raw body through: it pipes one read-only GET (via pfreq.sh, which handles
# auth/TLS) into a jq filter that selects ONLY the safe fields. The secret is
# never named, so it is never emitted (output.redact is a second-line backstop).
#
#   $1  API path under /api/v2 (pack-authored, fixed in the action argv).
#   $2  jq filter selecting the safe fields (pack-authored, fixed in the argv).
#
# Both args are fixed, pack-authored argv values — these actions take no LLM
# input — so nothing here is cloud-supplied.
set -eu

dir=$(dirname "$0")

# Bound the raw body before jq or shell capture. POSIX pipelines report only
# the last command, so retain the producer's status separately: HTTP failure
# must never become jq's successful empty input.
umask 077
response_dir=$(mktemp -d "${TMPDIR:-/tmp}/emisar-pfsense.XXXXXXXX") || exit 1
trap 'rm -f -- "$response_dir/body" "$response_dir/status"; rmdir -- "$response_dir"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if (
  if sh "$dir/pfreq.sh" GET "$1" --max-filesize 33554432; then status=0; else status=$?; fi
  printf '%s\n' "$status" >"$response_dir/status"
) | head -c 33554433 >"$response_dir/body"; then
  read_status=0
else
  read_status=$?
fi
bytes=$(wc -c <"$response_dir/body")
status=$(cat "$response_dir/status")
if [ "$bytes" -gt 33554432 ] || [ "$status" -eq 63 ]; then
  printf '%s\n' 'pfSense API response exceeded 32 MiB' >&2
  exit 1
fi
[ "$read_status" -eq 0 ] || exit "$read_status"
[ "$status" -eq 0 ] || exit "$status"
jq "$2" <"$response_dir/body"
