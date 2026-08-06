#!/usr/bin/env bash
# Seeds the disposable Airflow this pack's behavior cases run against, from
# inside the SUT container, and only then marks it healthy. Every case sees the
# same state: two parsed DAGs, one succeeded run, one failed run, a pool, a
# variable, and a connection — the last two carrying canaries the plan asserts
# never reach an action result.
set -euo pipefail

state_dir=/opt/airflow/state
seed_dag=packtest_pipeline
fail_dag=packtest_failing

log() { printf 'seed: %s\n' "$1" >&2; }

wait_for_dag() {
	local dag=$1 attempt
	for attempt in $(seq 1 180); do
		if airflow dags details "$dag" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	log "DAG $dag never parsed"
	return 1
}

# The Airflow CLI writes its own structured logs to the same stream as the
# document, so the JSON array is picked out of the noise rather than parsed
# from the whole stream.
run_state() {
	airflow dags list-runs "$1" -o json 2>/dev/null |
		python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("["):
        continue
    try:
        rows = json.loads(line)
    except ValueError:
        continue
    print(next((row.get("state", "") for row in rows if row.get("run_id") == sys.argv[1]), ""))
    break
' "$2"
}

wait_for_run() {
	local dag=$1 run_id=$2 want=$3 attempt state
	for attempt in $(seq 1 150); do
		state=$(run_state "$dag" "$run_id")
		if [[ $state == "$want" ]]; then
			return 0
		fi
		sleep 2
	done
	log "run $run_id of $dag reached '$state', wanted '$want'"
	return 1
}

mkdir -p "$state_dir"

wait_for_dag "$seed_dag"
wait_for_dag "$fail_dag"

log "creating pool, variable, and connection"
airflow pools set packtest_pool 4 "Pack-test pool" >/dev/null
airflow variables set packtest_variable "$PACKTEST_VARIABLE_VALUE" >/dev/null
airflow connections add packtest_conn \
	--conn-type postgres \
	--conn-host warehouse.packtest.invalid \
	--conn-port 5432 \
	--conn-schema analytics \
	--conn-login packtest \
	--conn-password "$PACKTEST_CONN_PASSWORD" \
	--conn-extra "{\"sslmode\":\"require\",\"api_token\":\"$PACKTEST_CONN_EXTRA_TOKEN\"}" >/dev/null

log "triggering seed runs"
airflow dags trigger "$seed_dag" --run-id packtest_seed_success >/dev/null
airflow dags trigger "$fail_dag" --run-id packtest_seed_failed >/dev/null

wait_for_run "$seed_dag" packtest_seed_success success
wait_for_run "$fail_dag" packtest_seed_failed failed

log "seeded"
touch "$state_dir/seeded"
