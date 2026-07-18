#!/bin/sh
# read_nsr.sh — packaged with the "nomad" emisar pack. emisar loads it from disk
# when the pack is trusted, journals its SHA-256 with every run, and runs it via
# /bin/sh. It is never fetched or assembled at request time.
#
# Runs a read-only nomad command with OPTIONAL -namespace / -region flags, so a
# single account can debug across namespaces/regions without changing the
# runner's ambient NOMAD_NAMESPACE / NOMAD_REGION. The command itself is fixed by
# the calling action — only the namespace, region, and the action's own bound
# positionals come from the cloud, and all are validated by the action schema
# before they reach here (no shell metacharacters), so this is not a
# cloud-controlled shell.
#
#   $1     namespace  ("" → omit -namespace, so the CLI keeps the ambient/default)
#   $2     region     ("" → omit -region, likewise)
#   $3     the fixed command head, e.g. "job status -verbose" — author-controlled
#          static tokens with no intra-token spaces, so word-splitting it is safe
#          and intended. The -namespace/-region flags are inserted at the END of
#          the head (after the subcommand, before any positional) because Go's
#          flag parser stops at the first positional.
#   $4...  the action's already-validated positionals (job id, alloc id, task, …)
#          An EMPTY positional is dropped entirely — that's how an action offers
#          an OPTIONAL trailing positional (a var prefix, a plugin id): the argv
#          template always fills the slot, and "" means "not given", never a
#          literal empty argument.
#
# An empty namespace/region drops the whole flag (POSIX ${var:+…}) rather than
# passing "-namespace=" — so we never clobber the operator's ambient value with
# an empty one.
set -eu
ns=$1
rg=$2
head=$3
shift 3
for a in "$@"; do
	shift
	[ -n "$a" ] && set -- "$@" "$a"
done
set -- $head ${ns:+-namespace=$ns} ${rg:+-region=$rg} "$@"
exec nomad "$@"
