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
