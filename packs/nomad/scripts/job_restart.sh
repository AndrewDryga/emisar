#!/bin/sh
# job_restart.sh — packaged with the "nomad" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via /bin/sh. It is never fetched or assembled at request time.
#
# Safe whole-job restart: `nomad job restart` restarts (or, in migrate mode,
# stops-and-replaces) a job's allocations in batches, waiting for each batch to
# come back up before the next — the incident verb that replaces N hand-rolled
# per-alloc restarts. Always runs non-interactively: -yes answers the prompts
# and -on-error=fail aborts instead of waiting for human input mid-run.
#
#   $1  job         job ID (validated, no shell metacharacters)
#   $2  batch_size  allocations per batch — "N" or "N%" (validated)
#   $3  mode        "in_place" → restart tasks inside the existing allocations
#                   "migrate"  → stop allocs and let the scheduler replace them
#                   (enum-validated; migrate maps to -reschedule)
#   $4  group       "" → all groups; else restrict to one task group
#   $5  task        "" → running tasks; else restrict to one task
#                   (only valid for in_place — the CLI rejects -task with
#                   -reschedule, and we let that surface as the error)
set -eu
job=$1
bs=$2
mode=$3
group=$4
task=$5

set -- -yes -on-error=fail -batch-size="$bs"
[ "$mode" = "migrate" ] && set -- "$@" -reschedule
[ -n "$group" ] && set -- "$@" -group="$group"
[ -n "$task" ] && set -- "$@" -task="$task"

# `--` stops flag parsing so a job name is never read as a nomad option.
exec nomad job restart "$@" -- "$job"
