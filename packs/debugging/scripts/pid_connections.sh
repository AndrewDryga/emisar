#!/bin/sh
# Consume the complete ss stream so the producer status remains observable,
# while emitting at most the validated number of matching PID-owned sockets.
set -eu
umask 077

pid=$1
limit=$2

if [ ! -d "/proc/$pid" ]; then
	printf 'debugging: PID %s does not exist\n' "$pid" >&2
	exit 1
fi

socket_dir=$(mktemp -d)
socket_pipe=$socket_dir/ss
ss_pid=
cleanup() {
	if [ -n "$ss_pid" ]; then
		kill "$ss_pid" 2>/dev/null || true
		wait "$ss_pid" 2>/dev/null || true
	fi
	rm -rf "$socket_dir"
}
trap cleanup EXIT HUP INT TERM
mkfifo "$socket_pipe"

ss -H -tunp >"$socket_pipe" &
ss_pid=$!
awk -v needle="pid=$pid," -v limit="$limit" '
	index($0, needle) && emitted < limit {
		print
		emitted++
	}
' "$socket_pipe"

if ! wait "$ss_pid"; then
	ss_pid=
	printf 'debugging: ss failed while inspecting PID %s\n' "$pid" >&2
	exit 1
fi
ss_pid=
