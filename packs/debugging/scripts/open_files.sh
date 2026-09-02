#!/bin/sh
# Count descriptor directory entries without resolving every target. A global
# lsof walk resolves every file/socket and becomes unusably slow precisely on
# the hosts where a process has leaked tens of thousands of descriptors.
set -eu

mode=$1

fd_count() {
	fd_dir=$1
	[ -d "$fd_dir" ] && [ -r "$fd_dir" ] || return 1
	set -- "$fd_dir"/*
	if [ "$1" = "$fd_dir/*" ]; then
		printf '0'
	else
		printf '%s' "$#"
	fi
}

process_name() {
	pid=$1
	name=
	IFS= read -r name <"/proc/$pid/comm" || name="?"
	printf '%s' "$name" | tr '\t\r\n' '   '
}

case "$mode" in
	top)
		tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-open-files.XXXXXX")
		trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
		rows=$tmp/rows
		: >"$rows"
		for fd_dir in /proc/[0-9]*/fd; do
			pid=${fd_dir#/proc/}
			pid=${pid%/fd}
			count=$(fd_count "$fd_dir") || continue
			name=$(process_name "$pid")
			printf '%s\t%s\t%s\n' "$count" "$pid" "$name" >>"$rows"
		done
		printf 'open_fds\tpid\tprocess\n'
		sort -k1,1nr -k2,2n "$rows" >"$tmp/sorted"
		head -n 20 "$tmp/sorted"
		;;

	pid-summary)
		pid=$2
		fd_dir=/proc/$pid/fd
		if [ ! -d "/proc/$pid" ]; then
			printf 'PID %s does not exist\n' "$pid" >&2
			exit 1
		fi
		count=$(fd_count "$fd_dir") || {
			printf 'cannot read open descriptors for PID %s\n' "$pid" >&2
			exit 1
		}
		set -- $(awk '$1 == "Max" && $2 == "open" && $3 == "files" {print $4, $5; exit}' "/proc/$pid/limits")
		if [ "$#" -ne 2 ]; then
			printf 'cannot read open-file limits for PID %s\n' "$pid" >&2
			exit 1
		fi
		soft_limit=$1
		hard_limit=$2
		usage_percent=-
		case "$soft_limit" in
			*[!0-9]*|0) ;;
			*) usage_percent=$(awk -v count="$count" -v limit="$soft_limit" 'BEGIN {printf "%.1f", count * 100 / limit}') ;;
		esac
		printf 'pid\tprocess\topen_fds\tsoft_limit\thard_limit\tusage_percent\n'
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$pid" "$(process_name "$pid")" "$count" "$soft_limit" "$hard_limit" "$usage_percent"
		;;

	*)
		printf 'unsupported open-files mode: %s\n' "$mode" >&2
		exit 2
		;;
esac
