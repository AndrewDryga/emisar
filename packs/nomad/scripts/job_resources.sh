#!/bin/sh
# job_resources.sh — packaged with the "nomad" emisar pack. emisar loads it
# from disk when the pack is trusted, journals its SHA-256 with every run, and
# runs it via /bin/sh. It is never fetched or assembled at request time.
#
# List the CPU / memory reservation and replica count for every task group and
# task in one job — the compact read companion to nomad.task_resources_set, so
# an operator (or LLM) can see current limits before vertical-scaling. Reads the
# full jobspec via `nomad job inspect` and projects only the resource fields.
#
# Positional args:
#   $1 namespace  "" keeps the runner's ambient/default namespace
#   $2 job        job ID
#
# Auth: the nomad CLI reads NOMAD_ADDR / NOMAD_TOKEN from the runner's inherited
# env. An explicit namespace overrides inherited NOMAD_NAMESPACE for this run.
# Requires jq on the host. Read-only.
set -eu

namespace=$1
job=$2
[ -z "$namespace" ] || export NOMAD_NAMESPACE="$namespace"

# `--` stops flag parsing so a job name is never read as a nomad option.
if ! spec=$(nomad job inspect -- "$job"); then
	exit 1
fi

printf '%s' "$spec" | jq -c '{
	job: .Job.ID,
	namespace: .Job.Namespace,
	groups: [ .Job.TaskGroups[] | {
		group: .Name,
		count: .Count,
		tasks: [ .Tasks[] | {
			task: .Name,
			cpu: .Resources.CPU,
			cores: .Resources.Cores,
			memory_mb: .Resources.MemoryMB,
			memory_max_mb: .Resources.MemoryMaxMB
		} ]
	} ]
}'
