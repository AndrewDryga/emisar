#!/bin/sh
# Aggregate the bounded, operator-relevant health surface for one Nomad job.
# The full jobspec is read locally but only identity, counts, driver names, and
# configured image names leave this script.
set -eu
umask 077

job=$1
namespace=$2
region=$3
allocation_limit=$4
events_per_task=$5
export NOMAD_CLI_NO_COLOR=1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

nomad_api() {
	if [ -n "$namespace" ] && [ -n "$region" ]; then
		NOMAD_NAMESPACE=$namespace NOMAD_REGION=$region nomad operator api -X GET "$@"
	elif [ -n "$namespace" ]; then
		NOMAD_NAMESPACE=$namespace nomad operator api -X GET "$@"
	elif [ -n "$region" ]; then
		NOMAD_REGION=$region nomad operator api -X GET "$@"
	else
		nomad operator api -X GET "$@"
	fi
}

nomad_cli() {
	if [ -n "$namespace" ] && [ -n "$region" ]; then
		NOMAD_NAMESPACE=$namespace NOMAD_REGION=$region nomad "$@"
	elif [ -n "$namespace" ]; then
		NOMAD_NAMESPACE=$namespace nomad "$@"
	elif [ -n "$region" ]; then
		NOMAD_REGION=$region nomad "$@"
	else
		nomad "$@"
	fi
}

run_stage() {
	stage=$1
	destination=$2
	shift 2
	if "$@" >"$destination"; then
		return
	else
		status=$?
		printf 'nomad.job_health_snapshot: %s failed\n' "$stage" >&2
		exit "$status"
	fi
}

require_json_type() {
	stage=$1
	type=$2
	path=$3
	if jq -e "type == \"$type\"" "$path" >/dev/null; then
		return
	else
		status=$?
		printf 'nomad.job_health_snapshot: %s returned invalid JSON; expected %s\n' "$stage" "$type" >&2
		exit "$status"
	fi
}

run_stage "job read" "$tmp/job.json" nomad_api "/v1/job/$job"
require_json_type "job read" object "$tmp/job.json"

# Pin subsequent list reads to the namespace returned for this exact job.
namespace=$(jq -er '.Namespace | strings | select(length > 0)' "$tmp/job.json")
run_stage "job summary read" "$tmp/summary.json" nomad_api "/v1/job/$job/summary"

# Cluster-wide list reads have broader discovery behavior on some ACL/version
# combinations even when filtered to one exact JobID. Use the job-scoped paths
# instead; they require only read-job on this namespace.
run_stage "job allocations read" "$tmp/all_allocations.json" \
	nomad_api "/v1/job/$job/allocations?all=false"
run_stage "job deployments read" "$tmp/all_deployments.json" \
	nomad_cli job deployments -json "$job"

require_json_type "job summary read" object "$tmp/summary.json"
require_json_type "job allocations read" array "$tmp/all_allocations.json"
require_json_type "job deployments read" array "$tmp/all_deployments.json"

jq -ce --argjson limit "$allocation_limit" \
	'sort_by(.ModifyTime // .CreateTime // 0) | reverse | .[:$limit]' \
	"$tmp/all_allocations.json" >"$tmp/allocations.json"
jq -ce 'sort_by(.ModifyIndex // .CreateIndex // 0) | reverse | .[:10]' \
	"$tmp/all_deployments.json" >"$tmp/deployments.json"
jq -r '.[].ID' "$tmp/allocations.json" >"$tmp/allocation_ids"
: >"$tmp/checks.ndjson"

while IFS= read -r allocation_id; do
	case "$allocation_id" in
		""|*[!0-9a-fA-F-]*)
			echo "nomad: API returned an invalid allocation ID" >&2
			exit 1
			;;
	esac
	run_stage "allocation $allocation_id checks read" "$tmp/current_checks.json" \
		nomad_api "/v1/allocation/$allocation_id/checks"
	require_json_type "allocation $allocation_id checks read" object "$tmp/current_checks.json"
	jq -cn \
		--arg allocation_id "$allocation_id" \
		--slurpfile checks "$tmp/current_checks.json" \
		'{allocation_id: $allocation_id, checks: $checks[0]}' \
		>>"$tmp/checks.ndjson"
done <"$tmp/allocation_ids"

jq -cn \
	--argjson event_limit "$events_per_task" \
	--slurpfile job "$tmp/job.json" \
	--slurpfile summary "$tmp/summary.json" \
	--slurpfile allocations "$tmp/allocations.json" \
	--slurpfile deployments "$tmp/deployments.json" \
	--slurpfile checks "$tmp/checks.ndjson" '
	def message:
		(. // "" | tostring | .[0:1024]);
	def event:
		{
			type: .Type,
			time: .Time,
			fails_task: (.FailsTask // false),
			message: (.DisplayMessage | message)
		};
	# Event types are matched case-insensitively without test(...; "i"): jq
	# links the regex family only when it was built against Oniguruma, and
	# every snapshot that carries a task state reaches these two filters.
	def task_state($event_limit):
		. as $state
		| ($state.value.Events // []) as $events
		| {
			task: .key,
			state: $state.value.State,
			failed: ($state.value.Failed // false),
			restarts: ($state.value.Restarts // 0),
			started_at: $state.value.StartedAt,
			finished_at: $state.value.FinishedAt,
			recent_restart_events: [
				$events[]
				| select(((.Type // "") | ascii_downcase) | contains("restart"))
			] | reverse | .[:$event_limit] | map(event),
			recent_failed_events: [
				$events[]
				| select(
					(.FailsTask // false) or
					(((.Type // "") | ascii_downcase)
					 | contains("failed") or contains("not restarting"))
				)
			] | reverse | .[:$event_limit] | map(event)
		};

	$job[0] as $job
	| $summary[0] as $summary
	| $allocations[0] as $allocations
	| $deployments[0] as $deployments
	| ($checks | map({key: .allocation_id, value: .checks}) | from_entries) as $checks_by_alloc
	| {
		job: {
			id: $job.ID,
			name: $job.Name,
			namespace: $job.Namespace,
			region: $job.Region,
			type: $job.Type,
			status: $job.Status,
			status_description: $job.StatusDescription,
			version: $job.Version,
			stopped: ($job.Stop // false)
		},
		allocation_totals: {
			desired: (
				if ($job.Type == "system" or $job.Type == "sysbatch")
				then null
				else ([$job.TaskGroups[]?.Count // 0] | add // 0)
				end
			),
			queued: ([$summary.Summary[]?.Queued // 0] | add // 0),
			starting: ([$summary.Summary[]?.Starting // 0] | add // 0),
			running: ([$summary.Summary[]?.Running // 0] | add // 0),
			complete: ([$summary.Summary[]?.Complete // 0] | add // 0),
			failed: ([$summary.Summary[]?.Failed // 0] | add // 0),
			lost: ([$summary.Summary[]?.Lost // 0] | add // 0),
			unknown: ([$summary.Summary[]?.Unknown // 0] | add // 0)
		},
		groups: [
			$job.TaskGroups[]? | . as $group | {
				name: $group.Name,
				desired_allocations: (
					if ($job.Type == "system" or $job.Type == "sysbatch")
					then null
					else $group.Count
					end
				),
				allocation_status: (
					$summary.Summary[$group.Name] // {}
					| {
						queued: (.Queued // 0),
						starting: (.Starting // 0),
						running: (.Running // 0),
						complete: (.Complete // 0),
						failed: (.Failed // 0),
						lost: (.Lost // 0),
						unknown: (.Unknown // 0)
					}
				),
				tasks: [
					$group.Tasks[]? | {
						name: .Name,
						driver: .Driver,
						image: (.Config.image // null)
					}
				]
			}
		],
		configured_images: [
			$job.TaskGroups[]? | . as $group
			| $group.Tasks[]?
			| select(.Config.image? != null)
			| {
				group: $group.Name,
				task: .Name,
				driver: .Driver,
				image: .Config.image
			}
		],
		deployments: [
			$deployments[] | {
				id: .ID,
				status: .Status,
				status_description: .StatusDescription,
				job_version: .JobVersion,
				create_index: .CreateIndex,
				modify_index: .ModifyIndex,
				task_groups: [
					(.TaskGroups // {} | to_entries[]) | {
						name: .key,
						desired_total: (.value.DesiredTotal // 0),
						placed_allocations: (.value.PlacedAllocs // 0),
						healthy_allocations: (.value.HealthyAllocs // 0),
						unhealthy_allocations: (.value.UnhealthyAllocs // 0),
						desired_canaries: (.value.DesiredCanaries // 0),
						promoted: (.value.Promoted // false)
					}
				]
			}
		],
		allocations: [
			$allocations[] | . as $allocation | {
				id: $allocation.ID,
				name: $allocation.Name,
				task_group: $allocation.TaskGroup,
				node_id: $allocation.NodeID,
				desired_status: $allocation.DesiredStatus,
				desired_description: $allocation.DesiredDescription,
				client_status: $allocation.ClientStatus,
				client_description: $allocation.ClientDescription,
				create_time: $allocation.CreateTime,
				modify_time: $allocation.ModifyTime,
				deployment: (
					if $allocation.DeploymentStatus == null then null
					else {
						canary: ($allocation.DeploymentStatus.Canary // false),
						healthy: $allocation.DeploymentStatus.Healthy,
						timestamp: $allocation.DeploymentStatus.Timestamp
					}
					end
				),
				tasks: [
					($allocation.TaskStates // {} | to_entries[])
					| task_state($event_limit)
				],
				checks: [
					($checks_by_alloc[$allocation.ID] // {} | to_entries[])
					| {
						id: (.value.ID // .key),
						name: .value.Check,
						group: .value.Group,
						service: .value.Service,
						mode: .value.Mode,
						status: .value.Status,
						timestamp: .value.Timestamp,
						output: (.value.Output | message)
					}
				]
			}
		]
	}'
