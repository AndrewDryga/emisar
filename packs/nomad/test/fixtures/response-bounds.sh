#!/bin/sh
# Execute the complete packaged script with the real selected Nomad CLI.
set -eu
mode=$1
fixture=http://nomad-response:8080
scratch=$(mktemp -d /tmp/nomad-response-test.XXXXXXXX)
mkdir "$scratch/tmp"
export TMPDIR="$scratch/tmp" NOMAD_ADDR="$fixture" NOMAD_TOKEN=response-fixture-token
child=
stop_child() {
  kill -TERM "-$child" 2>/dev/null || true
  for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  forced=false
  if kill -0 "$child" 2>/dev/null; then
    forced=true
    kill -KILL "-$child" 2>/dev/null || true
  fi
  child_status=0
  wait "$child" 2>/dev/null || child_status=$?
  child=
}
cleanup() {
  if [ -n "$child" ]; then
    stop_child
  fi
  rm -f "$scratch/out" "$scratch/err"
  rmdir "$scratch/tmp" "$scratch"
}
trap cleanup 0
trap 'exit 143' TERM
trap 'exit 130' INT

configure() {
  curl -fsS "$fixture/configure?mode=$1&size=$2" >/dev/null
}

assert_clean() {
  [ -z "$(ls -A "$TMPDIR")" ] || { echo 'Nomad response scratch files survived' >&2; exit 1; }
}

assert_request() {
  endpoint=$1
  prefix=Meta
  [ "$endpoint" != allocations ] || prefix=Job.Meta
  curl -fsS "$fixture/observed" | jq -e --arg path "/v1/$endpoint" --arg prefix "$prefix" '
    .path == $path and .token == "response-fixture-token" and
    .query.namespace == ["*"] and
    .query.filter == [($prefix + "[\"managed_by\"] == \"fixture\"")] and
    (if $path == "/v1/jobs" then .query.meta == ["true"] else .query.task_states == ["false"] end)
  ' >/dev/null
}

run_script() {
  /bin/sh /packs/nomad/scripts/by_meta.sh "$1" '*' managed_by fixture >"$scratch/out" 2>"$scratch/err"
}

case "$mode" in
length|chunked|close)
  for endpoint in jobs allocations; do
    for size in 33554431 33554432 33554433; do
      configure "$mode" "$size"
      status=0
      run_script "$endpoint" || status=$?
      if [ "$size" -gt 33554432 ]; then
        [ "$status" -ne 0 ] && [ ! -s "$scratch/out" ]
        grep -q 'Nomad API response exceeded 32 MiB' "$scratch/err"
      else
        [ "$status" -eq 0 ] || { cat "$scratch/err" >&2; exit 1; }
        jq -e 'length == 1 and .[0].ID == "fixture" and (.[0] | has("Unused") | not)' "$scratch/out" >/dev/null
        [ "$(wc -c <"$scratch/out")" -lt 1024 ]
      fi
      assert_request "$endpoint"
      assert_clean
    done
  done
  ;;
failures)
  for endpoint in jobs allocations; do
    for fault in 401 403 500 disconnect; do
      configure "$fault" 1024
      if run_script "$endpoint"; then echo "$fault incorrectly succeeded" >&2; exit 1; fi
      [ ! -s "$scratch/out" ]
      assert_request "$endpoint"
      assert_clean
    done
    configure empty 0
    run_script "$endpoint"
    [ ! -s "$scratch/out" ]
    assert_clean
  done
  ;;
producer)
  for endpoint in jobs allocations; do
    configure chunked 134217728
    if run_script "$endpoint"; then echo 'oversize producer succeeded' >&2; exit 1; fi
    [ ! -s "$scratch/out" ]
    grep -q 'Nomad API response exceeded 32 MiB' "$scratch/err"
    assert_request "$endpoint"
    # Permit socket/read-ahead buffers; the scratch file itself is cap+1.
    curl -fsS "$fixture/observed" | jq -e '.written < 41943040' >/dev/null
    assert_clean
  done
  ;;
cancel)
  configure hold 1024
  setsid /bin/sh /packs/nomad/scripts/by_meta.sh jobs '*' managed_by fixture >"$scratch/out" 2>"$scratch/err" &
  child=$!
  ready=false
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "$fixture/observed" | jq -e '.path == "/v1/jobs"' >/dev/null; then ready=true; break; fi
    sleep 0.1
  done
  [ "$ready" = true ]
  for response_dir in "$TMPDIR"/emisar-nomad.*; do
    [ "$(stat -c '%a' "$response_dir")" = 700 ]
    [ "$(stat -c '%a' "$response_dir/body")" = 600 ]
  done
  stop_child
  [ "$forced" = false ] || { echo 'TERM required KILL fallback' >&2; exit 1; }
  [ "$child_status" -ne 0 ] || { echo 'terminated response succeeded' >&2; exit 1; }
  assert_clean
  ;;
*) echo "unknown response probe: $mode" >&2; exit 2 ;;
esac
printf '%s\n' "Nomad response $mode verified"
