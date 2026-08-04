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

nomad_api "/v1/job/$job" >"$tmp/job.json"
jq -e 'type == "object"' "$tmp/job.json" >/dev/null

# Pin subsequent list reads to the namespace returned for this exact job.
namespace=$(jq -er '.Namespace | strings | select(length > 0)' "$tmp/job.json")
filter="JobID == \"$job\""

nomad_api "/v1/job/$job/summary" >"$tmp/summary.json"
nomad_api -filter "$filter" \
	"/v1/allocations?per_page=$allocation_limit&reverse=true" \
	>"$tmp/allocations.json"
nomad_api -filter "$filter" \
	"/v1/deployments?per_page=10&reverse=true" \
	>"$tmp/deployments.json"

jq -e 'type == "object"' "$tmp/summary.json" >/dev/null
jq -e 'type == "array"' "$tmp/allocations.json" >/dev/null
jq -e 'type == "array"' "$tmp/deployments.json" >/dev/null
jq -r '.[].ID' "$tmp/allocations.json" >"$tmp/allocation_ids"
: >"$tmp/checks.ndjson"

while IFS= read -r allocation_id; do
	case "$allocation_id" in
		""|*[!0-9a-fA-F-]*)
			echo "nomad: API returned an invalid allocation ID" >&2
			exit 1
			;;
	esac
	nomad_api "/v1/allocation/$allocation_id/checks" >"$tmp/current_checks.json"
	jq -e 'type == "object"' "$tmp/current_checks.json" >/dev/null
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
