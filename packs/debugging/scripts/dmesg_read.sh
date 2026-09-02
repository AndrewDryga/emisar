#!/bin/sh
# Read the source completely before filtering or truncating it. Otherwise a
# trailing grep/tail can hide a failed dmesg and journalctl fallback.
set -eu

mode=$1
lines=$2

tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-dmesg.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
source_output=$tmp/source

if dmesg -T 2>/dev/null >"$source_output"; then
	:
elif journalctl -k --no-pager -n "$lines" >"$source_output"; then
	:
else
	exit $?
fi

case "$mode" in
	tail)
		tail -n "$lines" "$source_output"
		;;
	oom)
		matches=$tmp/matches
		if grep -i -E 'oom|killed process|out of memory' "$source_output" >"$matches"; then
			tail -n 30 "$matches"
		else
			status=$?
			[ "$status" -eq 1 ] || exit "$status"
		fi
		;;
	*)
		printf 'unsupported dmesg read mode: %s\n' "$mode" >&2
		exit 2
		;;
esac
