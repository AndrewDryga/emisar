#!/bin/sh
# journalctl's --grep is optional at build time because it needs PCRE2. Read a
# bounded slice first, then apply ubiquitous POSIX extended-regex grep locally.
set -eu

unit=$1
since=$2
priority=$3
entry_limit=$4
pattern=$5

tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-journal-grep.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

if journalctl -u "$unit" --since "$since ago" -p "$priority" \
	--no-pager -n "$entry_limit" >"$tmp/journal"; then
	:
else
	status=$?
	printf 'journal read failed for %s\n' "$unit" >&2
	exit "$status"
fi

if grep -E -- "$pattern" "$tmp/journal" >"$tmp/matches"; then
	tail -n 500 "$tmp/matches"
else
	status=$?
	if [ "$status" -eq 1 ]; then
		exit 0
	fi
	printf 'invalid extended regular expression\n' >&2
	exit "$status"
fi
