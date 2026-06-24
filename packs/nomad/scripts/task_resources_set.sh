#!/bin/sh
# task_resources_set.sh — packaged with the "nomad" emisar pack. emisar loads
# it from disk when the pack is trusted, journals its SHA-256 with every run,
# and runs it via /bin/sh. It is never fetched or assembled at request time.
#
# Vertical-scale one task in place. Nomad has no atomic "set this task's CPU and
# memory" command — resources live in the jobspec — so this fetches the live
# spec, patches ONLY the named task's CPU / MemoryMB / MemoryMaxMB, and
# re-registers the job. The cloud never supplies jobspec JSON: it supplies only
# the bounded identifiers and integers below, and the jq program that performs
# the surgical edit is authored here.
#
# Positional args (rendered by the cloud-validated template engine into argv
# slots — never assembled into a shell string):
#   $1 job         job ID
#   $2 group       task group
#   $3 task        task name ("" selects the group's sole task, else errors)
#   $4 cpu         new CPU in MHz   (0 = leave unchanged)
#   $5 memory      new MemoryMB     (0 = leave unchanged)
#   $6 memory_max  new MemoryMaxMB  (0 = leave unchanged)
#
# Auth: the nomad CLI reads NOMAD_ADDR / NOMAD_TOKEN / NOMAD_NAMESPACE from the
# runner's inherited env. Requires jq on the host.
set -eu

job=$1
group=$2
task=$3
cpu=$4
memory=$5
memory_max=$6

if [ "$cpu" -le 0 ] && [ "$memory" -le 0 ] && [ "$memory_max" -le 0 ]; then
	echo "nothing to change: set at least one of cpu / memory / memory_max to a value > 0" >&2
	exit 2
fi

# Live spec — {"Job": {...}}, the exact shape `nomad job run -json` ingests.
# `--` stops flag parsing so a job name is never read as a nomad option.
if ! spec=$(nomad job inspect -- "$job"); then
	exit 1
fi

# Surgical patch: locate group -> task (fail loudly if missing or ambiguous),
# then set only the requested fields. Every other byte of the spec is preserved.
if ! patched=$(printf '%s' "$spec" | jq \
	--arg group "$group" \
	--arg task "$task" \
	--argjson cpu "$cpu" \
	--argjson memory "$memory" \
	--argjson memory_max "$memory_max" '
	(.Job.TaskGroups // []) as $groups
	| ([$groups[] | select(.Name == $group)] | first) as $g
	| if $g == null then error("group not found: \($group)") else . end
	| ($g.Tasks // []) as $tasks
	| (if $task == "" then
	     (if ($tasks | length) == 1 then $tasks[0].Name
	      else error("group \($group) has \($tasks | length) tasks; pass an explicit task (one of: \([$tasks[].Name] | join(", ")))") end)
	   else $task end) as $tname
	| if ([$tasks[] | select(.Name == $tname)] | length) == 0
	  then error("task not found: \($tname) in group \($group)") else . end
	| .Job.TaskGroups |= map(
	    if .Name == $group then
	      .Tasks |= map(
	        if .Name == $tname then
	          .Resources.CPU         = (if $cpu        > 0 then $cpu        else .Resources.CPU end)
	          | .Resources.MemoryMB    = (if $memory     > 0 then $memory     else .Resources.MemoryMB end)
	          | .Resources.MemoryMaxMB = (if $memory_max > 0 then $memory_max else .Resources.MemoryMaxMB end)
	        else . end)
	    else . end)'); then
	exit 1
fi

# Optimistic-concurrency guard: re-register only if the job has not changed
# since our inspect (JobModifyIndex must match). If the field is absent, submit
# without the guard rather than failing the action.
idx=$(printf '%s' "$spec" | jq -r '.Job.JobModifyIndex // empty')
case "$idx" in
	'' | *[!0-9]*)
		printf '%s' "$patched" | nomad job run -detach -json -
		;;
	*)
		printf '%s' "$patched" | nomad job run -detach -check-index "$idx" -json -
		;;
esac
