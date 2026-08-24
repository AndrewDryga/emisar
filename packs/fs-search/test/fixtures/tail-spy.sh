#!/bin/sh
set -eu

: > /tmp/packtest-tail-invoked

target=
for argument do
	target=$argument
done
if [ "$target" = "/proc/pressure/cpu" ]; then
	# Docker Desktop does not mount PSI files. Returning a fixed diagnostic line
	# proves the pack guard allowed the canonical path and invoked tail.
	printf '%s\n' 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0'
	exit 0
fi
case "$target" in
/ | /proc | /dev | /dev/* | /proc/kcore | /proc/*/environ | /proc/*/mem | /proc/*/fd | /proc/*/fd/*)
	exit 73
	;;
esac

exec /usr/bin/tail "$@"
