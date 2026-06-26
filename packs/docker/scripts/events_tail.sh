#!/bin/sh
# events_tail.sh — packaged with the "docker" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via /bin/sh. It is never fetched or assembled at request time.
#
# Replays docker daemon events for a bounded window, focused on the signals a
# preflight/incident actually cares about — container lifecycle + failures —
# because the default `docker events` feed is drowned in routine health-check
# exec_* chatter. The lifecycle/failure set is a fixed --filter allowlist; the
# noisy exec_* events are added only when include_exec is "true".
#
#   $1  minutes      how far back to replay (integer, bounded by the schema)
#   $2  include_exec "true" to also show exec_create/exec_start/exec_die
#
# Both args are validated by the action schema (integer / boolean) before they
# reach here and are passed as positionals, never interpolated into a shell
# command string.
set -eu
mins=$1
inc=${2:-}
set -- docker events --since "${mins}m" --until 0s \
	--filter event=create --filter event=start --filter event=restart \
	--filter event=stop --filter event=die --filter event=kill \
	--filter event=oom --filter event=destroy --filter event=health_status
[ "$inc" = "true" ] && set -- "$@" \
	--filter event=exec_create --filter event=exec_start --filter event=exec_die
exec "$@"
