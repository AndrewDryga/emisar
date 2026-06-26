#!/bin/sh
# pfcerts.sh — packaged with the "pfsense" emisar pack; emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via /bin/sh. Never fetched or assembled at request time.
#
# Reads from the pfSense certificate store, which can return private-key (`prv`)
# PEM. To make a leak structurally impossible, this does NOT pass the raw body
# through: it pipes one read-only GET (via pfreq.sh, which handles auth/TLS) into
# a jq filter that selects ONLY non-secret fields. The private key is never
# named, so it is never emitted (output.redact is a second-line backstop).
#
#   $1  API path under /api/v2 (pack-authored, fixed in the action argv).
#   $2  jq filter selecting the safe fields (pack-authored, fixed in the argv).
#
# Both args are fixed, pack-authored argv values — these actions take no LLM
# input — so nothing here is cloud-supplied.
dir=$(dirname "$0")
sh "$dir/pfreq.sh" GET "$1" | jq "$2"
