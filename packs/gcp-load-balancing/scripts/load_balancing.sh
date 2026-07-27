#!/bin/sh
set -eu

mode=$1
project=$2

scope_flag() {
  scope=$1
  location=$2
  case "$scope" in
    global)
      [ -z "$location" ] || {
        echo "location must be empty for global scope" >&2
        exit 2
      }
      printf '%s\n' --global
      ;;
    region)
      [ -n "$location" ] || {
        echo "location is required for region scope" >&2
        exit 2
      }
      printf '%s\n' "--region=$location"
      ;;
    *)
      echo "scope must be global or region" >&2
      exit 2
      ;;
  esac
}

project_backend='
  def header_names:
    [(. // [])[] | split(":")[0]];
  {
    name,
    region,
    loadBalancingScheme,
    protocol,
    portName,
    timeoutSec,
    healthChecks,
    backends: [(.backends // [])[] | {
      group,
      balancingMode,
      capacityScaler,
      maxUtilization,
      maxRate,
      maxRatePerEndpoint,
      maxConnections,
      maxConnectionsPerEndpoint
    }],
    sessionAffinity,
    affinityCookieTtlSec,
    connectionDraining,
    localityLbPolicy,
    enableCdn,
    cdnPolicy,
    securityPolicy,
    edgeSecurityPolicy,
    iapEnabled: (.iap.enabled // false),
    customRequestHeaderNames: (.customRequestHeaders | header_names),
    customResponseHeaderNames: (.customResponseHeaders | header_names)
  }
'

project_url_map='
  {
    name,
    region,
    defaultService,
    defaultUrlRedirect,
    hostRules,
    pathMatchers: [(.pathMatchers // [])[] | {
      name,
      defaultService,
      defaultUrlRedirect,
      pathRules: [(.pathRules // [])[] | {paths, service, urlRedirect}],
      routeRules: [(.routeRules // [])[] | {
        priority,
        service,
        urlRedirect,
        weightedBackends: [
          (.routeAction.weightedBackendServices // [])[] |
          {backendService, weight}
        ],
        headerActionPresent: has("headerAction")
      }],
      headerActionPresent: has("headerAction")
    }]
  }
'

project_health='
  map({
    backend,
    kind: .status.kind,
    healthStatus: [(.status.healthStatus // [])[] | {
      annotations,
      forwardingRule,
      forwardingRuleIp,
      healthState,
      instance,
      ipAddress,
      network,
      port,
      weight
    }]
  })
'

project_health_check='
  map({
    name,
    region,
    type,
    checkIntervalSec,
    timeoutSec,
    healthyThreshold,
    unhealthyThreshold,
    logEnabled: (.logConfig.enable // false),
    tcp: (.tcpHealthCheck // null | if . == null then null else {
      port, portName, portSpecification, proxyHeader
    } end),
    ssl: (.sslHealthCheck // null | if . == null then null else {
      port, portName, portSpecification, proxyHeader
    } end),
    http: (.httpHealthCheck // null | if . == null then null else {
      port, portName, portSpecification, proxyHeader, requestPath
    } end),
    https: (.httpsHealthCheck // null | if . == null then null else {
      port, portName, portSpecification, proxyHeader, requestPath
    } end),
    http2: (.http2HealthCheck // null | if . == null then null else {
      port, portName, portSpecification, proxyHeader, requestPath
    } end),
    grpc: (.grpcHealthCheck // null | if . == null then null else {
      port, portName, portSpecification, grpcServiceName
    } end)
  })
'

project_with_jq() {
  filter=$1
  shift
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  "$@" >"$tmp"
  jq -e "$filter" "$tmp"
}

case "$mode" in
  backend-services)
    project_with_jq "map($project_backend)" \
      gcloud compute backend-services list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  backend-service-describe)
    flag=$(scope_flag "$4" "$5")
    project_with_jq "$project_backend" \
      gcloud compute backend-services describe "$3" "$flag" \
      "--project=$project" --format=json --quiet
    ;;
  backend-health)
    flag=$(scope_flag "$4" "$5")
    project_with_jq "$project_health" \
      gcloud compute backend-services get-health "$3" "$flag" \
      "--project=$project" --format=json --quiet
    ;;
  health-checks)
    project_with_jq "$project_health_check" \
      gcloud compute health-checks list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  url-maps)
    project_with_jq "map($project_url_map)" \
      gcloud compute url-maps list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  http-proxies)
    exec gcloud compute target-http-proxies list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,region,urlMap)' \
      --quiet
    ;;
  https-proxies)
    exec gcloud compute target-https-proxies list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,region,urlMap,sslCertificates,certificateMap,sslPolicy,quicOverride,tlsEarlyData)' \
      --quiet
    ;;
  forwarding-rules)
    exec gcloud compute forwarding-rules list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,region,IPAddress,IPProtocol,portRange,ports,allPorts,allowGlobalAccess,allowPscGlobalAccess,backendService,target,loadBalancingScheme,network,subnetwork,networkTier,serviceLabel,serviceName,pscConnectionId,pscConnectionStatus)' \
      --quiet
    ;;
  network-endpoint-groups)
    exec gcloud compute network-endpoint-groups list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,zone,region,network,subnetwork,networkEndpointType,defaultPort,size,cloudRun,appEngine,cloudFunction,serverlessDeployment,pscData)' \
      --quiet
    ;;
  *)
    echo "unsupported load-balancing operation" >&2
    exit 2
    ;;
esac
