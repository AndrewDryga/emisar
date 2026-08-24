#!/bin/sh
# Keep low-risk content reads away from the few pseudo-files that expose
# process secrets or device streams. Path arguments have already been
# canonicalized by the runner before this script receives them.
set -eu

operation=${1-}
path=${2-}

if [ -z "$operation" ] || [ -z "$path" ]; then
	echo "fs-search: content reader requires an operation and path" >&2
	exit 1
fi
shift 2

is_digits() {
	case "$1" in
	"" | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

is_sensitive_process_path() {
	case "$1" in
	/proc/*) relative=${1#/proc/} ;;
	*) return 1 ;;
	esac

	pid=${relative%%/*}
	is_digits "$pid" || return 1
	[ "$relative" != "$pid" ] || return 1
	remainder=${relative#*/}

	case "$remainder" in
	environ | mem | fd | fd/*) return 0 ;;
	task/*)
		thread=${remainder#task/}
		tid=${thread%%/*}
		is_digits "$tid" || return 1
		[ "$thread" != "$tid" ] || return 1
		case "${thread#*/}" in
		environ | mem | fd | fd/*) return 0 ;;
		esac
		;;
	esac

	return 1
}

recursive_root_reaches_sensitive_path() {
	case "$1" in
	/ | /proc) return 0 ;;
	/proc/*) relative=${1#/proc/} ;;
	*) return 1 ;;
	esac

	pid=${relative%%/*}
	is_digits "$pid" || return 1
	[ "$relative" != "$pid" ] || return 0
	remainder=${relative#*/}

	case "$remainder" in
	task) return 0 ;;
	task/*)
		thread=${remainder#task/}
		tid=${thread%%/*}
		is_digits "$tid" || return 1
		[ "$thread" != "$tid" ] || return 0
		;;
	esac

	return 1
}

case "$path" in
/dev | /dev/* | /proc/kcore)
	echo "fs-search: refusing sensitive pseudo-filesystem path: $path" >&2
	exit 1
	;;
esac

if is_sensitive_process_path "$path"; then
	echo "fs-search: refusing sensitive pseudo-filesystem path: $path" >&2
	exit 1
fi

if [ "$operation" = "grep-recursive" ] && recursive_root_reaches_sensitive_path "$path"; then
	echo "fs-search: refusing recursive pseudo-filesystem root: $path" >&2
	exit 1
fi

case "$operation" in
head)
	[ "$#" -eq 1 ] || { echo "fs-search: head requires a line count" >&2; exit 1; }
	exec head -n "$1" -- "$path"
	;;
tail)
	[ "$#" -eq 1 ] || { echo "fs-search: tail requires a line count" >&2; exit 1; }
	exec tail -n "$1" -- "$path"
	;;
grep-file)
	[ "$#" -eq 2 ] || { echo "fs-search: grep-file requires a pattern and case mode" >&2; exit 1; }
	[ -r "$path" ] || { echo "file not readable: $path" >&2; exit 1; }
	if [ "$2" = "true" ]; then
		grep -i -E -e "$1" -- "$path" | head -n 2000
	elif [ "$2" = "false" ]; then
		grep -E -e "$1" -- "$path" | head -n 2000
	else
		echo "fs-search: invalid grep case mode: $2" >&2
		exit 1
	fi
	;;
grep-recursive)
	[ "$#" -eq 1 ] || { echo "fs-search: grep-recursive requires a pattern" >&2; exit 1; }
	exec grep -rEnH --no-messages -m 500 \
		--exclude-dir=.ssh --exclude-dir=ssh --exclude-dir=private --exclude-dir=sudoers.d \
		--exclude=shadow --exclude=gshadow --exclude=shadow- --exclude=gshadow- \
		--exclude=sudoers --exclude=kcore -e "$1" -- "$path"
	;;
*)
	echo "fs-search: unknown content reader operation: $operation" >&2
	exit 1
	;;
esac
