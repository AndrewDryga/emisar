#!/bin/sh
# Real server-generated children; the server-only SUT cannot place allocations.
set -eu
umask 077
mode=$1
kind=${2:-periodic}
namespace=${3:-default}
state=/tmp/packtest-nomad-child.json

create_child() {
	kind=$1
	namespace=$2
	parent=packtest-$kind
	if [ "$kind" = long ]; then
		parent=packtest-long-$(printf '%0150d' 0)
	fi
	[ "$namespace" = default ] || nomad namespace apply "$namespace" >/dev/null
	export NOMAD_NAMESPACE="$namespace"
	spec=$(mktemp /tmp/packtest-child.XXXXXX)
	printf 'job "%s" {\n datacenters = ["dc1"]\n type = "batch"\n' "$parent" >"$spec"
	case "$kind" in
	periodic|long|nested)
		printf ' periodic {\n cron = "0 0 1 1 *"\n prohibit_overlap = true\n }\n' >>"$spec"
		;;
	esac
	case "$kind" in
	dispatch|nested)
		printf ' parameterized { payload = "forbidden" }\n' >>"$spec"
		;;
	esac
	printf ' group "fixture" {\n task "wait" {\n driver = "raw_exec"\n config {\n command = "/bin/sleep"\n args = ["300"]\n }\n resources {\n cpu = 100\n memory = 64\n }\n }\n }\n}\n' >>"$spec"
	nomad job run -detach "$spec" >/dev/null
	rm -f "$spec"
	case "$kind" in
	dispatch|nested)
		child=$(printf '{}' | nomad operator api -X POST "/v1/job/$parent/dispatch" | jq -er .DispatchedJobID)
		[ "$kind" != nested ] || parent=$child
		;;
	esac
	case "$kind" in
	periodic|long|nested)
		nomad job periodic force -detach "$parent" >/dev/null
		child=
		for _attempt in 1 2 3 4 5 6 7 8 9 10; do
			child=$(nomad operator api -X GET /v1/jobs | jq -r --arg parent "$parent" '[.[] | select(.ParentID == $parent and .Periodic == false)] | if length == 1 then .[0].ID else empty end')
			[ -z "$child" ] || break
			sleep 0.25
		done
		if [ -z "$child" ]; then
			nomad operator api -X GET /v1/jobs | jq '[.[] | {ID,ParentID,Periodic,Dispatched}]' >&2
			echo 'Generated periodic child was not discovered' >&2
			exit 1
		fi
		;;
	esac
	case "$kind" in
	periodic|long) case "$child" in "$parent"/periodic-*) : ;; *) exit 1 ;; esac ;;
	dispatch) case "$child" in "$parent"/dispatch-*) : ;; *) exit 1 ;; esac ;;
	nested) case "$child" in packtest-nested/dispatch-*/periodic-*) : ;; *) exit 1 ;; esac ;;
	*) echo 'Unknown generated-job fixture' >&2; exit 2 ;;
	esac
	[ "$kind" != long ] || [ "${#child}" -gt 128 ]
	jq -cn --arg job "$child" --arg parent "$parent" --arg namespace "$namespace" '{job:$job,parent:$parent,namespace:$namespace}' >"$state"
	nomad job inspect "$child" | jq -e --arg job "$child" --arg parent "$parent" --arg ns "$namespace" '.Job.ID == $job and .Job.ParentID == $parent and .Job.Namespace == $ns' >/dev/null
}

case "$mode" in
setup) create_child "$kind" "$namespace" ;;
id) jq -er .job "$state" ;;
reads|isolation|bounds)
	scratch=$(mktemp -d /tmp/nomad-child-matrix.XXXXXX)
	action=setup
	finish() {
		status=$?
		if [ "$status" -ne 0 ]; then
			printf 'Generated-job check failed: %s / %s\n' "$kind" "$action" >&2
			[ ! -f "$scratch/result" ] || jq '{status,reason,stdout,stderr}' "$scratch/result" >&2
		fi
		rm -rf "$scratch"
		exit "$status"
	}
	trap finish EXIT
	trap 'exit 143' HUP INT TERM
	cp /workspace/test-packs/test-config.yaml "$scratch/config.yaml"
	chmod 600 "$scratch/config.yaml"
	if [ "$mode" = reads ]; then
		create_child "$kind" default
		child=$(jq -er .job "$state")
		parent=$(jq -er .parent "$state")
		for action in job_allocations job_status_one job_deployments job_history job_inspect job_resources job_health_snapshot; do
			emisar --config "$scratch/config.yaml" action run "nomad.$action" --arg "job=$child" --arg namespace=default --reason 'Inspect generated Nomad child' >"$scratch/result"
			jq -e '.status == "success" and .exit_code == 0' "$scratch/result" >/dev/null
			jq -r .stdout "$scratch/result" >"$scratch/out"
			case "$action" in
			job_inspect) jq -e --arg job "$child" --arg parent "$parent" '.Job.ID == $job and .Job.ParentID == $parent and .Job.Namespace == "default"' "$scratch/out" >/dev/null ;;
			job_resources) jq -e --arg job "$child" '.job == $job and .namespace == "default" and .groups[0].tasks[0].cpu == 100 and .groups[0].tasks[0].memory_mb == 64' "$scratch/out" >/dev/null ;;
			job_health_snapshot) jq -e --arg job "$child" '.job.id == $job and .job.namespace == "default" and .allocation_totals.desired == 1 and .allocations_available == 0 and .allocations == [] and .deployments == []' "$scratch/out" >/dev/null ;;
			job_status_one) grep -F "$child" "$scratch/out" >/dev/null ;;
			job_allocations) grep -F 'No allocations placed' "$scratch/out" >/dev/null ;;
			job_deployments) grep -F 'No deployments found' "$scratch/out" >/dev/null ;;
			job_history) grep -E '^Version[[:space:]]*=[[:space:]]*0$' "$scratch/out" >/dev/null ;;
			esac
		done
	fi
	# A default-namespace child cannot silently fall back when a different
	# namespace is supplied, even with a management token.
	if [ "$mode" = isolation ]; then
	child=$(jq -er .job "$state")
	nomad namespace apply packtest-ns >/dev/null
	if emisar --config "$scratch/config.yaml" action run nomad.job_health_snapshot --arg "job=$child" --arg namespace=packtest-ns --reason 'Reject a foreign-namespace child read' >"$scratch/result" 2>"$scratch/err"; then
		echo 'Foreign-namespace child read succeeded' >&2; exit 1
	fi
	jq -e '.status == "failed" and (.stderr | contains("nomad.job_health_snapshot: job read ")) and (.stdout // "") == ""' "$scratch/result" >/dev/null
	fi
	if [ "$mode" = bounds ]; then
		action=$2
		for bad in '-verbose' '/job' 'job/' 'job//child' 'job/../child' 'job%2Fchild' 'job?namespace=other' 'job#child' 'job;echo' 'job
child' "$(printf '%032769d' 0)"; do
			if emisar --config "$scratch/config.yaml" action run "nomad.$action" --arg "job=$bad" --reason 'Reject an unsafe Job ID' >"$scratch/result" 2>"$scratch/err"; then
				echo 'Unsafe Job ID accepted' >&2; exit 1
			fi
			jq -e '.status == "validation_failed" and .reason != "reason required" and (.executed_command // "") == ""' "$scratch/result" >/dev/null
		done
	fi
	printf 'Generated-job %s verified\n' "$mode"
	;;
*) exit 2 ;;
esac
