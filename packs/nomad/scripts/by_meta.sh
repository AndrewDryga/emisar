#!/bin/sh
# by_meta.sh — packaged with the "nomad" emisar pack. emisar loads it from disk
# when the pack is trusted, journals its SHA-256 with every run, and runs it via
# /bin/sh. It is never fetched or assembled at request time.
#
# Server-side meta-filtered discovery. Nomad's CLI has no -filter flag on the
# job/alloc list commands (checked through v2.0.4) — filtering by the job's
# `meta` stanza (managed_by=terraform, application=..., part_of=...) is HTTP
# API only. This wraps `nomad operator api` (which handles NOMAD_ADDR/TOKEN and
# the TLS env NOMAD_CACERT/NOMAD_CLIENT_CERT/NOMAD_CLIENT_KEY natively, and
# URL-encodes the -filter expression) and projects the response with jq to the
# compact fields an operator/LLM actually reads.
#
#   $1  endpoint   "jobs" | "allocations" — author-fixed by the calling action,
#                  never cloud-controlled
#   $2  namespace  "" → the default namespace; "*" → all namespaces (validated)
#   $3  meta_key   "" → no filter (list everything); else a job-meta key
#   $4  meta_value the exact value meta_key must equal
#
# meta_key/meta_value are schema-validated (anchored patterns, no quotes or
# backslashes), so interpolating them into the bexpr string literal below
# cannot break out of it. Requires jq on the runner host.
set -eu
ep=$1
ns=$2
k=$3
v=$4

case $ep in
jobs)
	# meta=true puts each job's Meta map in the list response; the filter
	# addresses it as Meta["key"].
	path="/v1/jobs?meta=true${ns:+&namespace=$ns}"
	expr_prefix='Meta'
	project='[.[] | {ID, ParentID, Namespace, Type, Status, Stop, Meta}]'
	;;
allocations)
	# Alloc list stubs never carry job meta, but the filter evaluates against
	# the full allocation, which embeds the job — so Job.Meta is addressable.
	path="/v1/allocations?task_states=false${ns:+&namespace=$ns}"
	expr_prefix='Job.Meta'
	project='[.[] | {ID, Name, JobID, Namespace, TaskGroup, NodeName, ClientStatus, DesiredStatus, JobVersion}]'
	;;
*)
	echo "by_meta.sh: unknown endpoint $ep" >&2
	exit 2
	;;
esac

if [ -n "$k" ] && [ -z "$v" ]; then
	echo "meta_value is required when meta_key is set" >&2
	exit 2
fi
if [ -z "$k" ] && [ -n "$v" ]; then
	echo "meta_key is required when meta_value is set" >&2
	exit 2
fi

if [ -n "$k" ]; then
	set -- -filter "${expr_prefix}[\"$k\"] == \"$v\""
else
	set --
fi

nomad operator api "$@" "$path" | jq -c "$project"
