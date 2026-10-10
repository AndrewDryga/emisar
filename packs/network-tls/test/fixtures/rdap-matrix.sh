#!/bin/bash
# Run through the actual executor with core jq; only the legacy WHOIS backend is
# a deliberate CLI shim. Every RDAP transfer reaches the owned HTTP server.
set -euo pipefail
umask 077
mode=$1
scratch=$(mktemp -d /tmp/packtest-rdap.XXXXXXXX)
finish() {
  status=$?
  if ((status != 0)); then
    printf 'RDAP matrix failed: mode=%s scenario=%s backend=%s count=%s\n' "$mode" "${scenario:-normal}" "${PACKTEST_WHOIS_MODE:-failure}" "${count:-0}" >&2
    [[ ! -f "$scratch/result" ]] || jq '{status,reason,exit_code,stdout,stderr}' "$scratch/result" >&2
    [[ ! -f "$scratch/err" ]] || cat "$scratch/err" >&2
  fi
  rm -f "$scratch/config" "$scratch/result" "$scratch/err"
  rmdir "$scratch"
  exit "$status"
}
trap finish EXIT
cp /workspace/test-packs/test-config.yaml "$scratch/config"
chmod 600 "$scratch/config"
export NET_RDAP_PACKTEST=1 NET_RDAP_BOOTSTRAP_URL=http://rdap-api:8080/bootstrap.json
export PATH=/opt/packtest-whois/bin:/opt/jq-without-regex:/opt/emisar/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PACKTEST_WHOIS_MODE=failure
count=0
select_case() { curl -fsS -X POST "http://rdap-api:8080/_select/$1" >/dev/null; }
observe() { curl -fsS http://rdap-api:8080/_observe | jq -e "$1" >/dev/null; }
run() {
  result_status=0
  emisar --config "$scratch/config" action run net.whois_summary --arg "domain=$1" \
    --reason 'Verify bounded registration summary' >"$scratch/result" 2>"$scratch/err" || result_status=$?
  # Check all result channels, not just stdout; the outer harness checks events.
  ! grep -Fq packtest-canary-rdap-contact-62c37 "$scratch/result" "$scratch/err"
  count=$((count + 1))
}
success() {
  [[ "$result_status" == 0 ]]
  jq -e '.status == "success" and .exit_code == 0 and (.stdout|utf8bytelength) <= 8192 and (.truncated_stdout // false) == false' "$scratch/result" >/dev/null
}
failure() {
  [[ "$result_status" != 0 ]]
  jq -e '.status == "failed" and (.stdout // "") == ""' "$scratch/result" >/dev/null
}
case "$mode" in
fallback)
  for backend in failure partial empty empty-fields unrecognized oversize; do
    select_case normal
    export PACKTEST_WHOIS_MODE=$backend
    run EXAMPLE.DEV.
    success
    jq -e '.stdout | contains("Source: RDAP") and contains("Registrar: \"Fixture RDAP Registrar\"") and contains("Registrar IANA ID: \"9999\"") and contains("Event \"expiration\": \"2030-01-02T03:04:05Z\"") and contains("Nameserver: \"ns1.example.dev\"")' "$scratch/result" >/dev/null
    observe '.whois == ["example.dev"] and .requests == ["/bootstrap.json", "/rdap/domain/example.dev"]'
  done
  select_case normal
  export PACKTEST_WHOIS_MODE=success
  run example.dev
  success
  jq -e '.stdout | contains("Source: WHOIS") and contains("Fixture WHOIS Registrar") and contains("2030-01-02T03:04:05Z") and (contains("abuse")|not)' "$scratch/result" >/dev/null
  observe '.whois == ["example.dev"] and .requests == []'
  ;;
bootstrap)
  for scenario in suffix candidates mixed-controls; do
    select_case "$scenario"
    run example.dev
    success
    observe '.requests == ["/bootstrap.json", "/rdap/domain/example.dev"]'
  done
  for scenario in bad-base bad-newline bad-nul bad-bootstrap no-service bootstrap-redirect bootstrap-error bootstrap-large; do
    select_case "$scenario"
    run example.dev
    failure
    observe '.requests == ["/bootstrap.json"]'
  done
  ;;
responses)
  for scenario in redirect error error-object wrong-name multi malformed bad-events bad-registrar bad-nameservers; do
    select_case "$scenario"
    run example.dev
    failure
    observe '.requests == ["/bootstrap.json", "/rdap/domain/example.dev"]'
  done
  select_case minimal
  run example.dev
  success
  jq -e '.stdout == "Source: RDAP\nDomain: \"example.dev\"\n"' "$scratch/result" >/dev/null
  select_case controls
  run example.dev
  success
  jq -e '.stdout | contains("Fixture\\nRegistrar\\u001b[31m") and (contains("Fixture\nRegistrar")|not)' "$scratch/result" >/dev/null
  ;;
bounds)
  select_case exact
  run example.dev
  success
  jq -e '.stdout | contains("Fixture RDAP Registrar") and (contains("Summary clipped")|not)' "$scratch/result" >/dev/null
  for scenario in large chunked-large; do
    select_case "$scenario"
    run example.dev
    failure
    jq -e '.stderr | contains("exceeded 16 MiB")' "$scratch/result" >/dev/null
  done
  select_case clip
  run example.dev
  success
  jq -e '.stdout | contains("Summary clipped at 8 KiB") and contains("ns-0000.example.dev") and (contains("ns-0999.example.dev")|not)' "$scratch/result" >/dev/null
  ;;
inputs)
  select_case normal
  for domain in example..dev example.dev.. example.-bad.dev example.bad-.dev 127.0.0.1 example \
    "$(printf '%064d' 0).dev" 'example.dev?x=1' 'user@example.dev' 'example.dev/path' 'example.dev%2f'; do
    run "$domain"
    [[ "$result_status" != 0 ]]
    jq -e '(.stdout // "") == "" and
      ((.status == "validation_failed" and .reason == "argument_invalid") or
       (.status == "failed" and .exit_code == 1 and (.stderr|contains("Invalid domain name"))))' "$scratch/result" >/dev/null
  done
  observe '.requests == [] and .whois == []'
  export NET_RDAP_BOOTSTRAP_URL=http://unselected.invalid/bootstrap.json
  run example.dev
  failure
  observe '.requests == [] and .whois == []'
  export NET_RDAP_PACKTEST=0 NET_RDAP_BOOTSTRAP_URL=http://rdap-api:8080/bootstrap.json
  run example.dev
  failure
  observe '.requests == [] and .whois == []'
  ;;
*) exit 2 ;;
esac
printf 'RDAP %s: %s executor cases verified\n' "$mode" "$count"
