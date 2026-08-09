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

# Capture before filtering. Piped straight into jq, a failed request (401, 403,
# a 404 path, an unreachable host) sent jq empty stdin — and jq exits 0 on empty
# input, so the action reported SUCCESS with no findings. "Are any certificates
# expiring?" answered "no" from an auth failure.
body=$(sh "$dir/pfreq.sh" GET "$1")
printf '%s' "$body" | jq "$2"
