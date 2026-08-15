#!/bin/sh
# Build a bounded incident view from local-agent endpoints without returning
# the raw metrics document, check output, service metadata, or the ACL token.
set -eu
umask 077

sample_seconds=$1
limit=$2
base_url=${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}
base_url=${base_url%/}

snapshot_dir=$(mktemp -d)
trap 'rm -rf "$snapshot_dir"' EXIT HUP INT TERM
headers=$snapshot_dir/headers
: >"$headers"
if [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
	printf 'X-Consul-Token: %s\n' "$CONSUL_HTTP_TOKEN" >"$headers"
fi

consul_get() {
	path=$1
	destination=$2
	curl -fsS --globoff --proto '=http,https' \
		--connect-timeout 2 --max-time 10 \
		-H @"$headers" "$base_url$path" >"$destination"
}

consul_get /v1/agent/metrics "$snapshot_dir/metrics-before.json"
jq -e 'type == "object" and (.Counters | type == "array")' \
	"$snapshot_dir/metrics-before.json" >/dev/null

sleep "$sample_seconds"

consul_get /v1/agent/metrics "$snapshot_dir/metrics-after.json"
consul_get /v1/agent/self "$snapshot_dir/self.json"
consul_get /v1/agent/services "$snapshot_dir/services.json"
consul_get /v1/agent/checks "$snapshot_dir/checks.json"

jq -e 'type == "object" and (.Counters | type == "array")' \
	"$snapshot_dir/metrics-after.json" >/dev/null
jq -e 'type == "object"' "$snapshot_dir/self.json" >/dev/null
jq -e 'type == "object"' "$snapshot_dir/services.json" >/dev/null
jq -e 'type == "object"' "$snapshot_dir/checks.json" >/dev/null

jq -cn \
	--argjson sample_seconds "$sample_seconds" \
	--argjson limit "$limit" \
	--slurpfile before "$snapshot_dir/metrics-before.json" \
	--slurpfile after "$snapshot_dir/metrics-after.json" \
	--slurpfile self "$snapshot_dir/self.json" \
	--slurpfile services "$snapshot_dir/services.json" \
	--slurpfile checks "$snapshot_dir/checks.json" '
	# Catalog register/deregister are timers in Samples; ACL-blocked
	# mutations are Counters. Both expose the operation count as Count.
	def operation_total($document; $name):
		[(($document.Counters // []) + ($document.Samples // []))[]?
			| select(.Name == $name)
			| (.Count // 0)]
		| add // 0;
	def interval_delta($name):
		if $before[0].Timestamp == $after[0].Timestamp then
			null
		else
			operation_total($after[0]; $name)
		end;
	def service_item:
		{
			id: (.ID // ""),
			name: (.Service // ""),
			address: (.Address // ""),
			port: (.Port // 0),
			kind: (.Kind // "")
		};
	def loopback:
		((.address | tostring | ascii_downcase) as $address
		 | ($address == "localhost"
			or $address == "::1"
			or $address == "[::1]"
			or ($address | startswith("127."))));

	interval_delta("consul.acl.blocked.check.deregistration") as $blocked_check_deregistration
	| interval_delta("consul.acl.blocked.check.registration") as $blocked_check_registration
	| interval_delta("consul.acl.blocked.node.registration") as $blocked_node_registration
	| interval_delta("consul.acl.blocked.service.deregistration") as $blocked_service_deregistration
	| interval_delta("consul.acl.blocked.service.registration") as $blocked_service_registration
	| ($services[0]
		| to_entries
		| map(.value | service_item)
		| sort_by(.id)) as $local_services
	| ($local_services | map(select(loopback))) as $loopback_services
	| ($checks[0]
		| to_entries
		| map(.value
			| select(((.Status // "unknown") | ascii_downcase) != "passing")
			| {
				id: (.CheckID // ""),
				name: (.Name // ""),
				status: (.Status // "unknown"),
				service_id: (.ServiceID // ""),
				service_name: (.ServiceName // "")
			  })
		| sort_by(.id)) as $failing_checks
	| {
		sample_seconds: $sample_seconds,
		metric_window: {
			before: $before[0].Timestamp,
			after: $after[0].Timestamp,
			changed: ($before[0].Timestamp != $after[0].Timestamp)
		},
		agent: {
			node: ($self[0].Config.NodeName // $self[0].Member.Name // null),
			datacenter: ($self[0].Config.Datacenter // null)
		},
		mutation_deltas: {
			registrations: interval_delta("consul.catalog.register"),
			deregistrations: interval_delta("consul.catalog.deregister"),
			blocked: {
				total: (if $before[0].Timestamp == $after[0].Timestamp then
					null
				else
					(
						$blocked_check_deregistration
						+ $blocked_check_registration
						+ $blocked_node_registration
						+ $blocked_service_deregistration
						+ $blocked_service_registration
					)
				end),
				check_deregistrations: $blocked_check_deregistration,
				check_registrations: $blocked_check_registration,
				node_registrations: $blocked_node_registration,
				service_deregistrations: $blocked_service_deregistration,
				service_registrations: $blocked_service_registration
			}
		},
		local_services: {
			count: ($local_services | length),
			truncated: (($local_services | length) > $limit),
			items: $local_services[:$limit]
		},
		failing_checks: {
			count: ($failing_checks | length),
			truncated: (($failing_checks | length) > $limit),
			items: $failing_checks[:$limit]
		},
		suspicious_loopback_registrations: {
			count: ($loopback_services | length),
			truncated: (($loopback_services | length) > $limit),
			items: $loopback_services[:$limit]
		}
	}'
