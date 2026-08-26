#!/bin/sh
# Make one fixed Consul HTTP API request. The action owns the method, path, and
# extra curl flags; inherited Consul variables only select the destination,
# credentials, and TLS material.
set -eu

method=$1
path=$2
shift 2

case $method in
GET | PUT) ;;
*)
	printf 'unsupported Consul API method: %s\n' "$method" >&2
	exit 2
	;;
esac

case $path in
/v1/*) ;;
*)
	printf 'Consul API path must start with /v1/: %s\n' "$path" >&2
	exit 2
	;;
esac

base_url=${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}
base_url=${base_url%/}

[ -n "${CONSUL_CACERT:-}" ] && set -- --cacert "$CONSUL_CACERT" "$@"
if { [ -n "${CONSUL_CLIENT_CERT:-}" ] && [ -z "${CONSUL_CLIENT_KEY:-}" ]; } ||
	{ [ -z "${CONSUL_CLIENT_CERT:-}" ] && [ -n "${CONSUL_CLIENT_KEY:-}" ]; }; then
	printf 'CONSUL_CLIENT_CERT and CONSUL_CLIENT_KEY must be set together\n' >&2
	exit 2
fi
[ -n "${CONSUL_CLIENT_CERT:-}" ] && set -- --cert "$CONSUL_CLIENT_CERT" "$@"
[ -n "${CONSUL_CLIENT_KEY:-}" ] && set -- --key "$CONSUL_CLIENT_KEY" "$@"

if [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
	printf 'X-Consul-Token: %s\n' "$CONSUL_HTTP_TOKEN" |
		curl -q -fsS --globoff --proto '=http,https' -H @- -X "$method" "$@" "$base_url$path"
else
	curl -q -fsS --globoff --proto '=http,https' -X "$method" "$@" "$base_url$path"
fi
