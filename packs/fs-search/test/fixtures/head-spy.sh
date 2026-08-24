#!/bin/sh
set -eu

: > /tmp/packtest-head-invoked

target=
for argument do
	target=$argument
done
case "$target" in
/ | /proc | /dev | /dev/* | /proc/kcore | /proc/*/environ | /proc/*/mem | /proc/*/fd | /proc/*/fd/*)
	exit 73
	;;
esac

exec /usr/bin/head "$@"
