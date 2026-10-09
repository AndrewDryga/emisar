#!/bin/sh
# Supplement the real ACL server with HTTP protocol faults through the real client.
set -eu
umask 077
scratch=$(mktemp -d /tmp/nomad-api-test.XXXXXXXX)
mkdir "$scratch/tmp"
step=initialization
cleanup() {
	result=$?
	if [ "$result" -ne 0 ]; then
		printf 'Nomad API probe failed at %s\n' "$step" >&2
		[ ! -f "$scratch/err" ] || cat "$scratch/err" >&2
	fi
	rm -rf -- "$scratch"
}
trap cleanup 0
export TMPDIR="$scratch/tmp" NOMAD_ADDR=http://nomad-response:8080
export NOMAD_TOKEN=packtest-canary-nomad-api-token
fixture=http://nomad-response:8080
configure() { curl -fsS "$fixture/configure?mode=$1" >/dev/null; }
run() {
	/bin/sh /packs/nomad/scripts/api.sh "$1" "$2" "$3" "${4:-}" "${5:-}" >"$scratch/out" 2>"$scratch/err"
}
assert_clean() { [ -z "$(ls -A "$TMPDIR")" ]; }
for endpoint in /v1/agent/self /v1/agent/members /v1/nodes /v1/operator/autopilot/health \
	/v1/status/leader /v1/node/11111111-2222-3333-4444-555555555555/purge \
	/v1/client/allocation/11111111-2222-3333-4444-555555555555/stats \
	'/v1/client/fs/ls/11111111-2222-3333-4444-555555555555?path=local/logs' \
	'/v1/client/fs/stat/11111111-2222-3333-4444-555555555555?path=local/app.log'; do
	method=GET; kind=object
	case "$endpoint" in
	*/purge) method=PUT ;;
	/v1/nodes|*/fs/ls/*) kind=array ;;
	/v1/status/leader) kind=string ;;
	esac
	configure api-ok
	step="$endpoint success"
	run "$method" "$endpoint" "$kind" packtest-ns packtest-region
	jq -es --arg kind "$kind" 'length == 1 and (.[0] | type) == $kind' "$scratch/out" >/dev/null
	[ ! -s "$scratch/err" ]
	curl -fsS "$fixture/observed" | jq -e --arg method "$method" --arg path "${endpoint%%\?*}" '
		.method == $method and .path == $path and .query.namespace == ["packtest-ns"] and
		.query.region == ["packtest-region"] and .token == "packtest-canary-nomad-api-token"
	' >/dev/null
	assert_clean
	for mode in api-401 api-403 api-429 api-500 api-redirect api-html api-empty api-multiple; do
		configure "$mode"
		step="$endpoint $mode"
		if run "$method" "$endpoint" "$kind"; then echo "$endpoint $mode incorrectly succeeded" >&2; exit 1; fi
		[ ! -s "$scratch/out" ]
		case "$mode" in
		api-401|api-403|api-429|api-500) grep -q 'fixture API rejection' "$scratch/err" ;;
		api-redirect) grep -q 'fixture redirect' "$scratch/err" ;;
		api-html) grep -q 'fixture non-JSON response' "$scratch/err" ;;
		api-empty) grep -q 'invalid JSON response' "$scratch/err" ;;
		api-multiple) grep -q '{} {}' "$scratch/err" ;;
		esac
		curl -fsS "$fixture/observed" | jq -e '.redirected == 0' >/dev/null
		assert_clean
	done
done
configure api-empty-leader
step=empty-leader
run GET /v1/status/leader string
[ "$(cat "$scratch/out")" = '""' ]
assert_clean
configure api-ok
step=ambient-auth
export NOMAD_NAMESPACE=ambient-ns NOMAD_REGION=ambient-region NOMAD_HTTP_AUTH='fixture:packtest-canary-nomad-api-basic'
run GET /v1/agent/self object
expected_auth=$(printf '%s' "$NOMAD_HTTP_AUTH" | base64 | tr -d '\n')
curl -fsS "$fixture/observed" | jq -e --arg auth "Basic $expected_auth" '
	.query.namespace == ["ambient-ns"] and .query.region == ["ambient-region"] and .authorization == $auth
' >/dev/null
if grep -q 'packtest-canary' "$scratch/out" "$scratch/err"; then echo 'Nomad API leaked credentials' >&2; exit 1; fi
assert_clean
export NOMAD_ADDR='http://ignored:packtest-canary-ignored@nomad-response:8080'
step=auth-precedence
run GET /v1/agent/self object
curl -fsS "$fixture/observed" | jq -e --arg auth "Basic $expected_auth" '.authorization == $auth' >/dev/null
assert_clean
export NOMAD_HTTP_AUTH=username_only NOMAD_ADDR=http://nomad-response:8080
step=username-only
run GET /v1/agent/self object
expected_auth=$(printf '%s' 'username_only:' | base64 | tr -d '\n')
curl -fsS "$fixture/observed" | jq -e --arg auth "Basic $expected_auth" '.authorization == $auth' >/dev/null
assert_clean
unset NOMAD_HTTP_AUTH NOMAD_NAMESPACE NOMAD_REGION
export NOMAD_ADDR=unix:///fixture-sockets/nomad.sock
step=unix-socket
run GET /v1/agent/self object
grep -q 'Nomad API' "$scratch/out"
assert_clean

export NOMAD_ADDR=http://nomad-response:8443 NOMAD_TLS_SERVER_NAME=consul
export NOMAD_CLIENT_CERT=/packs/nomad/test/fixtures/tls/client.pem
export NOMAD_CLIENT_KEY=/packs/nomad/test/fixtures/tls/client-key.pem
export NOMAD_CACERT=/packs/nomad/test/fixtures/tls/ca.pem NOMAD_SKIP_VERIFY=false
configure api-ok
step=tls-ca-file
run GET /v1/agent/self object
grep -q 'Nomad API' "$scratch/out"
curl -fsS "$fixture/observed" | jq -e '.host == "nomad-response:8443"' >/dev/null
assert_clean

# Config quoting and curl's filename:password grammar are separate layers.
cert_path=$(printf '%s/client:quoted"name\\path.pem' "$scratch")
cp /packs/nomad/test/fixtures/tls/client.pem "$cert_path"
export NOMAD_CLIENT_CERT="$cert_path"
step=tls-certificate-filename
run GET /v1/agent/self object
assert_clean
export NOMAD_CLIENT_CERT=/packs/nomad/test/fixtures/tls/client.pem

# Go's PEM reader accepts trailing spaces and tabs on delimiter lines.
awk '/^-----/ { printf "%s \t\n", $0; next } { print }' /packs/nomad/test/fixtures/tls/ca.pem >"$scratch/ca-spaced.pem"
export NOMAD_CACERT="$scratch/ca-spaced.pem"
step=tls-ca-whitespace
run GET /v1/agent/self object
assert_clean
unset NOMAD_CACERT

mkdir -p "$scratch/ca/nested"
cp /packs/nomad/test/fixtures/tls/ca.pem "$scratch/ca/nested/plain.pem"
export NOMAD_CAPATH="$scratch/ca"
unset NOMAD_CACERT
step=tls-ca-directory
run GET /v1/agent/self object
assert_clean

# A CA file takes precedence over even an invalid CA directory.
export NOMAD_CACERT=/packs/nomad/test/fixtures/tls/ca.pem NOMAD_CAPATH=/does-not-exist
step=tls-ca-precedence
run GET /v1/agent/self object
assert_clean

export NOMAD_TLS_SERVER_NAME=wrong-name
step=tls-verified-name
if run GET /v1/agent/self object; then echo 'false skip_verify accepted an untrusted name' >&2; exit 1; fi
[ ! -s "$scratch/out" ]
assert_clean
export NOMAD_SKIP_VERIFY=true
step=tls-skip-verify
run GET /v1/agent/self object
assert_clean

for invalid in ca client; do
	step="invalid-$invalid"
	configure api-ok
	export NOMAD_TLS_SERVER_NAME=consul
	if [ "$invalid" = ca ]; then
		export NOMAD_CACERT=/does-not-exist
	else
		export NOMAD_CACERT=/packs/nomad/test/fixtures/tls/ca.pem
		unset NOMAD_CLIENT_KEY
	fi
	if run GET /v1/agent/self object; then echo 'invalid native TLS material succeeded' >&2; exit 1; fi
	grep -q 'Invalid Nomad client configuration' "$scratch/err"
	curl -fsS "$fixture/observed" | jq -e 'has("path") | not' >/dev/null
	assert_clean
done
printf '%s\n' 'Nomad API response contract verified'
