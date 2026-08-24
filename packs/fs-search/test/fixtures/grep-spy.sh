#!/bin/sh
set -eu

: > /tmp/packtest-grep-invoked

target=
for argument do
	target=$argument
done
case "$target" in
/ | /proc | /proc/1 | /proc/1/task | /proc/1/task/1 | /dev | /dev/* | /proc/kcore | /proc/*/environ | /proc/*/mem | /proc/*/fd | /proc/*/fd/*)
	exit 73
	;;
esac

exec /usr/bin/grep "$@"
