#!/bin/sh
set -eu
mode=$1
namespace=${2:-default}
case "$mode" in
setup)
  nomad namespace apply "$namespace" >/dev/null
  nomad job run -detach -namespace="$namespace" /packs/nomad/test/fixtures/node.nomad.hcl >/dev/null
  attempts=0
  until nomad job allocs -json -namespace="$namespace" packtest-node | jq -e 'any(.[]; .ClientStatus == "running" and .DesiredStatus == "run")' >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || { echo 'Node fixture allocation did not start' >&2; exit 1; }
    sleep 1
  done
  ;;
id)
  nomad job allocs -json -namespace="$namespace" packtest-node | jq -er '[.[] | select(.ClientStatus == "running" and .DesiredStatus == "run")][0].ID'
  ;;
private)
  curl -fsS --globoff --proto =http http://nomad-response:8080/observed | jq -e '(.path | startswith("/node-")) and .authorization == null and .redirected == 0' >/dev/null
  alloc_id=$(nomad job allocs -json packtest-node | jq -er '[.[] | select(.ClientStatus == "running")][0].ID')
  nomad alloc exec -i=false -t=false -task node "$alloc_id" test ! -e /tmp/packtest-node-coverage
  echo 'Node probe did not forward credentials, follow redirects or write coverage'
  ;;
bounds)
  scratch=$(mktemp -d /tmp/nomad-node-bounds.XXXXXX)
  trap 'rm -rf "$scratch"' EXIT
  cp /workspace/test-packs/test-config.yaml "$scratch/config.yaml"
  chmod 600 "$scratch/config.yaml"
  # Literal command substitutions are hostile inputs, never commands to run.
  # shellcheck disable=SC2016
  for url in 'http://consul/' 'https://user:password@consul/' 'https://consul/?password=value' 'https://consul/#value' 'https://consul/;id' 'https://consul/$(id)' "$(printf 'https://consul/%01024d' 0)"; do
    if emisar --config "$scratch/config.yaml" action run nomad.alloc_exec_node_https --arg alloc_id=abc12345 --arg task=node --arg "url=$url" --reason 'Reject unsafe HTTPS arguments' >"$scratch/result" 2>"$scratch/err"; then
      echo 'Unsafe HTTPS argument accepted' >&2; exit 1
    fi
    jq -e '.status == "validation_failed" and .reason == "argument_invalid" and (.executed_command // "") == ""' "$scratch/result" >/dev/null
  done
  # shellcheck disable=SC2016
  for hostname in '-flag' 'host;id' 'host/../file' '$(id)' "$(printf '%0254d' 0)"; do
    if emisar --config "$scratch/config.yaml" action run nomad.alloc_exec_node_dns --arg alloc_id=abc12345 --arg task=node --arg "hostname=$hostname" --reason 'Reject unsafe DNS arguments' >"$scratch/result" 2>"$scratch/err"; then
      echo 'Unsafe DNS argument accepted' >&2; exit 1
    fi
    jq -e '.status == "validation_failed" and .reason == "argument_invalid" and (.executed_command // "") == ""' "$scratch/result" >/dev/null
  done
  echo 'Node probe argument bounds verified'
  ;;
*) exit 2 ;;
esac
