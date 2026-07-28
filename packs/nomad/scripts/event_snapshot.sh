#!/bin/sh
# event_snapshot.sh — packaged with the "nomad" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs it
# via /bin/sh. It is never fetched or assembled at request time.
#
# A BOUNDED snapshot of Nomad's event stream. Nomad has no "last N events" query —
# /v1/event/stream is a forward-streaming NDJSON feed whose only history is the
# broker's replay buffer (the last ~100 events). So this reads the stream from
# index=1 (which replays the buffer, then live events) for a fixed number of
# SECONDS, capped at a fixed byte size, then returns. `timeout` ends the stream
# and `head` caps the bytes, so the pipeline exits 0 with whatever events arrived
# in the window — no hung action, no kill, no partial-output guesswork.
#
#   $1  seconds    the snapshot window (a bounded integer from the action schema)
#   $2  topic      "" → all topics; else one Nomad event topic (enum, validated)
#   $3  namespace  "" → ambient/default; else a namespace (validated, no metachars)
#
# topic and namespace are validated by the action schema (an anchored topic
# whitelist + a namespace pattern with no shell/URL metacharacters) before they
# reach here, so interpolating them into the query string is safe. An empty value
# drops the whole query param (POSIX ${var:+…}) rather than sending "&topic=".
set -u
secs=$1
topic=$2
ns=$3
url="/v1/event/stream?index=1${topic:+&topic=$topic}${ns:+&namespace=$ns}"

# The window elapsing is the NORMAL end of a bounded snapshot, so timeout's 124
# is a success here — but nomad's own failures (unreachable agent, bad ACL
# token, unknown namespace) are not, and piping straight into head reported
# every one of them as an empty, successful snapshot. Capture to a file rather
# than a variable: the feed is NDJSON that the 256 KiB cap exists to bound, and
# a variable would hold it all before truncating.
snapshot=$(mktemp) || exit 1
trap 'rm -f "$snapshot"' EXIT

timeout "$secs" nomad operator api "$url" > "$snapshot"
status=$?

head -c 262144 "$snapshot"

case "$status" in
	0 | 124) exit 0 ;;
	*) exit "$status" ;;
esac
