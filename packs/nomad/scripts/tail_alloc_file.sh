#!/bin/sh
# tail_alloc_file.sh — packaged with the "nomad" emisar pack. emisar loads it
# from disk when the pack is trusted, journals its SHA-256 with every run, and
# runs it via /bin/sh. It is never fetched or assembled at request time.
#
# Tails a file inside one allocation, with the ONE guard the action's arg schema
# cannot express: the path must not name the secrets/ tree.
#
# Why here and not in a pattern: the runner's regexes are RE2, which has no
# lookahead, so "any path except one starting with secrets/" has no readable
# regex. The alternative — denied_paths — resolves its rules against the RUNNER's
# own filesystem (EvalSymlinks over real files), which is the wrong filesystem
# entirely: this path is interpreted inside a remote allocation. So the check is
# an explicit author-controlled comparison, done before nomad is invoked.
#
#   $1     namespace  ("" → omit -namespace, keeping the ambient/default)
#   $2     region     ("" → omit -region, likewise)
#   $3     line count, already bounded 1..500 by the action schema
#   $4     allocation id
#   $5     path inside the allocation
#
# Every value is validated by the action schema before it arrives (no shell
# metacharacters), so this is not a cloud-controlled shell.
set -eu

ns=$1
rg=$2
lines=$3
alloc=$4
path=$5

# Reject the secrets/ tree by its first segment. Nomad mounts rendered
# credentials there, and a leading "./" or "/" is stripped first so the check
# cannot be walked around with a cosmetic prefix. A task that renders a
# credential somewhere ELSE is what the action's medium tier is for; no string
# check can find that.
normalized=$path
while :; do
	case $normalized in
	./*) normalized=${normalized#./} ;;
	/*) normalized=${normalized#/} ;;
	*) break ;;
	esac
done

case $normalized in
secrets | secrets/*)
	echo "refusing to read the allocation's secrets/ tree: $path" >&2
	exit 1
	;;
esac

set -- alloc fs -tail -n "$lines" ${ns:+-namespace=$ns} ${rg:+-region=$rg} "$alloc" "$normalized"
exec nomad "$@"
