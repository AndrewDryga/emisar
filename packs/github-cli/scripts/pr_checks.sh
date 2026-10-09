#!/bin/sh
set -eu
export LC_ALL=C GH_PROMPT_DISABLED=1

mode=$1
repo=$2
pr=$3
case "$mode" in checks|view) ;; *) exit 2 ;; esac
umask 077
scratch=$(mktemp -d) || exit $?
trap 'rm -f "$scratch/details" "$scratch/checks" "$scratch/errors" "$scratch/statuses" "$scratch/runs" "$scratch/jobs" "$scratch/head" "$scratch/projected-statuses" "$scratch/projected-runs" "$scratch/run" "$scratch/projected-jobs" "$scratch/next-runs" "$scratch/projection" "$scratch/final"; rmdir "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
# Never replay raw provider error bodies, headers or credential-bearing URLs.
read_gh() {
  file=$1
  phase=$2
  shift 2
  rc=0
  gh "$@" >"$file" 2>"$scratch/errors" || rc=$?
  [ "$rc" -eq 0 ] || fail "GitHub $phase read failed (exit $rc); check access, rate limits and connectivity." "$rc"
  size=$(wc -c <"$file") || exit $?
  [ "$size" -le 4194304 ] || fail "GitHub $phase response exceeds the 4 MiB input bound."
}
shape() {
  file=$1
  filter=$2
  jq -es "length == 1 and (.[0] | $filter)" "$file" >/dev/null 2>&1 || fail 'GitHub response has an invalid JSON shape.'
}

fields=headRefOid,headRefName
if [ "$mode" = view ]; then fields=number,title,body,state,author,createdAt,mergedAt,reviewDecision,headRefOid,headRefName; fi
read_gh "$scratch/details" 'PR details' pr view "$pr" --repo "$repo" --json "$fields"
shape "$scratch/details" 'type == "object" and (.headRefOid | type == "string") and (.headRefName | type == "string")'
if [ "$mode" = view ]; then
  jq -e --argjson pr "$pr" 'def text: . == null or type == "string"; .number == $pr and ([.title,.body,.state,.createdAt,.reviewDecision] | all(.[]; type == "string")) and (.author | . == null or (type == "object" and ([.login,.id,.name] | all(.[]; text)) and (.is_bot | . == null or type == "boolean"))) and (.mergedAt | text)' "$scratch/details" >/dev/null || fail 'GitHub returned invalid PR details.'
fi
sha=$(jq -r .headRefOid "$scratch/details") || exit $?
branch=$(jq -r .headRefName "$scratch/details") || exit $?
case "$sha" in ''|*[!a-fA-F0-9]*) fail 'GitHub returned an invalid head commit.' ;; esac
case "${#sha}" in 40|64) ;; *) fail 'GitHub returned an invalid head commit length.' ;; esac

rc=0
gh pr checks "$pr" --repo "$repo" --json name,state,bucket,workflow,link,startedAt,completedAt,description,event >"$scratch/checks" 2>"$scratch/errors" || rc=$?
if [ "$rc" -eq 0 ]; then
  size=$(wc -c <"$scratch/checks") || exit $?
  [ "$size" -le 4194304 ] || fail 'GitHub checks response exceeds the 4 MiB input bound.'
  shape "$scratch/checks" 'type == "array" and all(.[]; type == "object" and ([.name,.state,.bucket,.workflow,.link,.startedAt,.completedAt,.description,.event] | all(.[]; type == "string")) and (.bucket as $bucket | ["pass","fail","pending","skipping","cancel"] | index($bucket) != null))'
  # All native check contexts remain available, subject to the response bound.
  jq -cn --arg sha "$sha" --slurpfile checks "$scratch/checks" '{head_sha:$sha,source:"check_contexts",non_actions_check_runs:"visible",checks:[$checks[0][] | {name,state,bucket,workflow,link,startedAt,completedAt,description,event}]}' >"$scratch/projection"
else
  # Only the actual check-context permission diagnostic is a capability gap.
  # Mixed/other failures remain failures; no blanket exit-1/8 normalization.
  permission=false
  if awk '
    NF {
      if ($0 !~ /^GraphQL: /) { bad=1; next }
      sub(/^GraphQL: /, "")
      n=split($0, errors, ", ")
      for (i=1; i<=n; i++) {
        seen=1
        if (errors[i] !~ /^Resource not accessible by personal access token \([A-Za-z0-9_.]*[.]statusCheckRollup[.]contexts[.][A-Za-z0-9_.]+\)$/) bad=1
      }
    }
    END { exit (!seen || bad) }
  ' "$scratch/errors"; then permission=true; fi
  diagnostic=$(cat "$scratch/errors") || exit $?
  if [ "$permission" != true ]; then
    [ "$diagnostic" = "no checks reported on the '$branch' branch" ] || fail "GitHub checks read failed (exit $rc); check access, rate limits and connectivity." "$rc"
  fi

  read_gh "$scratch/statuses" 'commit statuses' api --method GET "repos/$repo/commits/$sha/status?per_page=100&page=1"
  shape "$scratch/statuses" 'type == "object" and (.statuses | type == "array" and length <= 100) and (.total_count | type == "number" and . >= 0 and . <= 9007199254740991 and floor == .) and (.state | . == "success" or . == "failure" or . == "pending")'
  jq -e --arg sha "$sha" 'def text: . == null or type == "string"; .sha == $sha and .total_count >= (.statuses | length) and all(.statuses[]; type == "object" and (.context | type == "string") and (.state | . == "success" or . == "failure" or . == "error" or . == "pending") and ([.description,.target_url,.created_at,.updated_at] | all(.[]; text)))' "$scratch/statuses" >/dev/null || fail 'GitHub returned invalid commit status data.'
  jq -c '{state,total_count,truncated:(.total_count > (.statuses | length)),statuses:[.statuses[] | {context,state,description,target_url,created_at,updated_at}]}' "$scratch/statuses" >"$scratch/projected-statuses"

  read_gh "$scratch/runs" 'Actions runs' api --method GET "repos/$repo/actions/runs?head_sha=$sha&per_page=100&page=1"
  shape "$scratch/runs" 'type == "object" and (.workflow_runs | type == "array" and length <= 100) and (.total_count | type == "number" and . >= 0 and . <= 9007199254740991 and floor == .)'
  jq -e --arg sha "$sha" 'def id: type == "number" and . > 0 and . <= 9007199254740991 and floor == .; def text: . == null or type == "string"; .total_count >= (.workflow_runs | length) and all(.workflow_runs[]; type == "object" and (.id | id) and (.run_attempt | id) and .head_sha == $sha and (.status | type == "string") and ([.name,.conclusion,.html_url,.created_at,.updated_at] | all(.[]; text)))' "$scratch/runs" >/dev/null || fail 'GitHub returned invalid Actions run data.'
  count=$(jq -r '.workflow_runs[:10] | length' "$scratch/runs") || exit $?
  printf '%s\n' '[]' >"$scratch/projected-runs"
  index=0
  while [ "$index" -lt "$count" ]; do
    jq -c --argjson i "$index" '.workflow_runs[$i] | {id,run_attempt,name,status,conclusion,html_url,created_at,updated_at}' "$scratch/runs" >"$scratch/run"
    id=$(jq -r .id "$scratch/run") || exit $?
    attempt=$(jq -r .run_attempt "$scratch/run") || exit $?
    read_gh "$scratch/jobs" 'Actions attempt jobs' api --method GET "repos/$repo/actions/runs/$id/attempts/$attempt/jobs?per_page=100&page=1"
    shape "$scratch/jobs" 'type == "object" and (.jobs | type == "array" and length <= 100) and (.total_count | type == "number" and . >= 0 and . <= 9007199254740991 and floor == .)'
    jq -e --arg sha "$sha" --argjson id "$id" --argjson attempt "$attempt" 'def valid_id: type == "number" and . > 0 and . <= 9007199254740991 and floor == .; def text: . == null or type == "string"; .total_count >= (.jobs | length) and all(.jobs[]; type == "object" and (.id | valid_id) and .head_sha == $sha and .run_id == $id and ((has("run_attempt") | not) or .run_attempt == $attempt) and (.name | type == "string") and (.status | type == "string") and ([.conclusion,.html_url,.started_at,.completed_at] | all(.[]; text)))' "$scratch/jobs" >/dev/null || fail 'GitHub returned invalid Actions job data.'
    jq -c '{total_count,truncated:(.total_count > (.jobs | length)),jobs:[.jobs[] | {id,name,status,conclusion,html_url,started_at,completed_at}]}' "$scratch/jobs" >"$scratch/projected-jobs"
    jq -cn --slurpfile runs "$scratch/projected-runs" --slurpfile run "$scratch/run" --slurpfile jobs "$scratch/projected-jobs" '$runs[0] + [$run[0] + {attempt_jobs:$jobs[0]}]' >"$scratch/next-runs"
    mv "$scratch/next-runs" "$scratch/projected-runs"
    index=$((index + 1))
  done
  total=$(jq -r .total_count "$scratch/runs") || exit $?
  jq -cn --arg sha "$sha" --slurpfile statuses "$scratch/projected-statuses" --slurpfile runs "$scratch/projected-runs" --argjson total "$total" '{head_sha:$sha,source:"actions_and_commit_statuses",non_actions_check_runs:"not_visible",commit_status:$statuses[0],actions:{total_count:$total,truncated:($total > ($runs[0] | length)),runs:$runs[0]}}' >"$scratch/projection"
fi

# A PR may move while collecting either path. Never label another head's data
# as current. REST jobs describe the attempt observed, not an atomic snapshot.
read_gh "$scratch/head" 'PR head recheck' pr view "$pr" --repo "$repo" --json headRefOid
shape "$scratch/head" 'type == "object" and (.headRefOid | type == "string")'
current=$(jq -r .headRefOid "$scratch/head") || exit $?
[ "$current" = "$sha" ] || fail 'The PR head changed during the read; retry for the new commit.'
if [ "$mode" = view ]; then
  jq -cn --slurpfile details "$scratch/details" --slurpfile checks "$scratch/projection" '$details[0] | {number,title,body,state,author:(.author | if . == null then null else {login,id,name,is_bot} end),createdAt,mergedAt,reviewDecision,headRefOid,headRefName,statusCheckRollup:$checks[0]}' >"$scratch/final"
else
  mv "$scratch/projection" "$scratch/final"
fi
size=$(wc -c <"$scratch/final") || exit $?
[ "$size" -le 524288 ] || fail 'GitHub result exceeds the 512 KiB output bound; no truncated JSON was returned.'
cat "$scratch/final"
