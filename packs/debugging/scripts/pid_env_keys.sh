#!/bin/sh
# GNU awk reads the NUL-delimited environ directly, so values never pass through
# a shell variable, pipeline, or temporary file.
set -eu

pid=$1
environ=/proc/$pid/environ

if [ ! -e "$environ" ]; then
	printf 'debugging: PID %s does not exist\n' "$pid" >&2
	exit 1
fi

LC_ALL=C awk '
	BEGIN { RS = "\0" }
	/^[A-Za-z_][A-Za-z0-9_]*=/ {
		separator = index($0, "=")
		key = substr($0, 1, separator - 1)
		if (!seen[key]++) print key
	}
' "$environ"
