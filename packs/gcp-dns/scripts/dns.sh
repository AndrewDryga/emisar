#!/bin/sh
set -eu

mode=$1
project=$2

project_with_jq() {
  filter=$1
  shift
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  "$@" >"$tmp"
  jq -e "$filter" "$tmp"
}

zone_projection='
  {
    name,
    dnsName,
    visibility,
    nameServers,
    dnssecConfig,
    privateVisibilityNetworks: [
      (.privateVisibilityConfig.networks // [])[] | .networkUrl
    ],
    forwardingTargets: [
      (.forwardingConfig.targetNameServers // [])[] |
      {ipv4Address, forwardingPath}
    ],
    peeringTargetNetwork: .peeringConfig.targetNetwork.networkUrl,
    serviceDirectoryNamespace: .serviceDirectoryConfig.namespace.namespaceUrl
  }
'

case "$mode" in
  zones)
    project_with_jq "map($zone_projection)" \
      gcloud dns managed-zones list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  zone-describe)
    project_with_jq "$zone_projection" \
      gcloud dns managed-zones describe "$3" \
      "--project=$project" --format=json --quiet
    ;;
  record-lookup)
    exec gcloud dns record-sets list \
      "--zone=$3" "--name=$4" "--type=$5" \
      "--project=$project" --limit=100 \
      '--format=json(name,type,ttl,rrdatas,routingPolicy,signatureRrdatas)' \
      --quiet
    ;;
  record-upsert)
    zone=$3 name=$4 rtype=$5 ttl=$6 values=$7
    current=$(gcloud dns record-sets list \
      "--zone=$zone" "--name=$name" "--type=$rtype" \
      "--project=$project" --limit=2 --format=json --quiet)
    if printf '%s' "$current" | jq -e 'length == 0' >/dev/null; then
      exec gcloud dns record-sets create "$name" \
        "--zone=$zone" "--type=$rtype" "--ttl=$ttl" "--rrdatas=$values" \
        "--project=$project" --format=json --quiet
    fi
    exec gcloud dns record-sets update "$name" \
      "--zone=$zone" "--type=$rtype" "--ttl=$ttl" "--rrdatas=$values" \
      "--project=$project" --format=json --quiet
    ;;
  record-delete)
    zone=$3 name=$4 rtype=$5 values=$6
    current=$(gcloud dns record-sets list \
      "--zone=$zone" "--name=$name" "--type=$rtype" \
      "--project=$project" --limit=2 --format=json --quiet)
    if ! printf '%s' "$current" | jq -e --arg values "$values" \
      'length == 1 and ((.[0].rrdatas // []) | sort) == ($values | split(",") | sort)' \
      >/dev/null; then
      printf '%s\n' \
        "live record set does not match the expected values; refusing to delete" >&2
      exit 3
    fi
    # Delete through a DNS change so the provider re-verifies the exact live
    # record data at apply time: a concurrent modification fails the change
    # instead of deleting whatever replaced it.
    ttl=$(printf '%s' "$current" | jq -r '.[0].ttl')
    umask 077
    txdir=$(mktemp -d)
    trap 'rm -rf -- "$txdir"' EXIT HUP INT TERM
    old_ifs=$IFS
    set -f
    IFS='
'
    set -- $(printf '%s' "$current" | jq -r '.[0].rrdatas[]')
    set +f
    IFS=$old_ifs
    gcloud dns record-sets transaction start \
      "--zone=$zone" "--project=$project" \
      "--transaction-file=$txdir/transaction.yaml" --skip-soa-update --quiet >&2
    gcloud dns record-sets transaction remove "$@" \
      "--name=$name" "--ttl=$ttl" "--type=$rtype" \
      "--zone=$zone" "--project=$project" \
      "--transaction-file=$txdir/transaction.yaml" --quiet >&2
    gcloud dns record-sets transaction execute \
      "--zone=$zone" "--project=$project" \
      "--transaction-file=$txdir/transaction.yaml" --format=none --quiet >&2
    printf '%s' "$current" | jq '.[0] | {name, type, ttl, rrdatas, deleted: true}'
    ;;
  policies)
    project_with_jq \
      'map({
        name,
        enableInboundForwarding,
        enableLogging,
        networks: [(.networks // [])[] | .networkUrl],
        alternativeNameServers: [
          (.alternativeNameServerConfig.targetNameServers // [])[] |
          {ipv4Address, forwardingPath}
        ]
      })' \
      gcloud dns policies list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  response-policies)
    project_with_jq \
      'map({
        responsePolicyName,
        networks: [(.networks // [])[] | .networkUrl],
        gkeClusters: [(.gkeClusters // [])[] | .gkeClusterName],
        behavior
      })' \
      gcloud dns response-policies list \
      "--project=$project" "--location=$3" "--limit=$4" --format=json --quiet
    ;;
  response-policy-rules)
    project_with_jq \
      'map({
        ruleName,
        dnsName,
        behavior,
        localData
      })' \
      gcloud dns response-policies rules list "$3" \
      "--project=$project" "--location=$4" "--limit=$5" --format=json --quiet
    ;;
  *)
    echo "unsupported DNS operation" >&2
    exit 2
    ;;
esac
