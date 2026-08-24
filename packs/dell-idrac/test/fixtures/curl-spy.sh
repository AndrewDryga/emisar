#!/bin/sh
set -u

blocked=false
for argument in "$@"; do
	case "$argument" in
	https://blocked-target/*) blocked=true ;;
	esac
done

if [ "$blocked" != "true" ]; then
	exec /usr/bin/curl "$@"
fi

printf 'PACKTEST_CLIENT_INVOKED curl blocked-target\n' >&2
: >/tmp/packtest-idrac-curl-invoked
output_file=
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-o" ] && [ "$#" -gt 1 ]; then
		shift
		output_file=$1
	fi
	shift
done
[ -z "$output_file" ] || printf '{}\n' >"$output_file"
printf '200'
