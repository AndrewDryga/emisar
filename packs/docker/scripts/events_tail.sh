#!/bin/sh
# events_tail.sh — packaged with the "docker" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via /bin/sh. It is never fetched or assembled at request time.
#
# Replays docker daemon events for a bounded window, focused on the signals a
# preflight/incident actually cares about — container lifecycle + failures —
# because the default `docker events` feed is drowned in routine health-check
# exec_* chatter. The lifecycle/failure set is a fixed --filter allowlist. exec_*
# events are never added: exec_create and exec_start print the command line they
# ran, and a health check's can carry a password.
#
#   $1  minutes      how far back to replay (integer, bounded by the schema)
#
# The arg is validated by the action schema (integer) before it reaches here and
# is passed as a positional, never interpolated into a shell command string.
set -eu
mins=$1
exec docker events --since "${mins}m" --until 0s \
	--filter event=create --filter event=start --filter event=restart \
	--filter event=stop --filter event=die --filter event=kill \
	--filter event=oom --filter event=destroy --filter event=health_status
