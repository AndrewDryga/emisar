#!/bin/sh
set -eu

mode=$1
project=$2

case "$mode" in
  networks)
    exec gcloud compute networks list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,autoCreateSubnetworks,mtu,routingConfig.routingMode,subnetworks,peerings)' \
      --quiet
    ;;
  network-describe)
    exec gcloud compute networks describe "$3" \
      "--project=$project" \
      '--format=json(name,autoCreateSubnetworks,mtu,routingConfig.routingMode,subnetworks,peerings)' \
      --quiet
    ;;
  subnets)
    exec gcloud compute networks subnets list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,region,network,ipCidrRange,stackType,ipv6AccessType,externalIpv6Prefix,purpose,role,privateIpGoogleAccess,secondaryIpRanges,state)' \
      --quiet
    ;;
  subnet-describe)
    exec gcloud compute networks subnets describe "$3" \
      "--region=$4" "--project=$project" \
      '--format=json(name,region,network,ipCidrRange,stackType,ipv6AccessType,externalIpv6Prefix,purpose,role,privateIpGoogleAccess,secondaryIpRanges,state)' \
      --quiet
    ;;
  firewall-rules)
    exec gcloud compute firewall-rules list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,network,direction,priority,disabled,sourceRanges,destinationRanges,sourceTags,targetTags,sourceServiceAccounts,targetServiceAccounts,allowed,denied,logConfig.enabled)' \
      --quiet
    ;;
  routes)
    exec gcloud compute routes list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,network,destRange,priority,routeType,status,routeStatus,nextHopGateway,nextHopInstance,nextHopIp,nextHopNetwork,nextHopVpnTunnel,nextHopIlb,nextHopHub)' \
      --quiet
    ;;
  addresses)
    exec gcloud compute addresses list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,address,addressType,ipVersion,purpose,network,subnetwork,region,status,users,networkTier)' \
      --quiet
    ;;
  routers)
    exec gcloud compute routers list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,region,network,bgp.asn,bgp.advertiseMode,bgp.advertisedGroups,nats.name,nats.natIpAllocateOption,nats.sourceSubnetworkIpRangesToNat,nats.enableEndpointIndependentMapping)' \
      --quiet
    ;;
  router-status)
    exec gcloud compute routers get-status "$3" \
      "--region=$4" "--project=$project" \
      '--format=json(result.bgpPeerStatus,result.bestRoutes,result.bestRoutesForRouter)' \
      --quiet
    ;;
  nat-describe)
    exec gcloud compute routers nats describe "$3" \
      "--router=$4" "--region=$5" "--project=$project" \
      '--format=json(name,natIpAllocateOption,natIps,sourceSubnetworkIpRangesToNat,subnetworks,enableEndpointIndependentMapping,endpointTypes,logConfig,rules.ruleNumber,rules.match,rules.action.sourceNatActiveIps,rules.action.sourceNatDrainIps)' \
      --quiet
    ;;
  vpn-tunnels)
    exec gcloud compute vpn-tunnels list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,region,status,detailedStatus,peerIp,peerExternalGateway,peerGcpGateway,vpnGateway,targetVpnGateway,router,ikeVersion,interface,localTrafficSelector,remoteTrafficSelector)' \
      --quiet
    ;;
  vpn-gateway-status)
    exec gcloud compute vpn-gateways get-status "$3" \
      "--region=$4" "--project=$project" \
      '--format=json(result.vpnConnections)' \
      --quiet
    ;;
  interconnect-attachments)
    exec gcloud compute interconnects attachments list \
      "--project=$project" "--limit=$3" \
      '--format=json(name,region,state,type,edgeAvailabilityDomain,interconnect,router,vlanTag8021q,bandwidth,cloudRouterIpAddress,customerRouterIpAddress,mtu,stackType,adminEnabled,operationalStatus)' \
      --quiet
    ;;
  interconnect-diagnostics)
    exec gcloud compute interconnects get-diagnostics "$3" \
      "--project=$project" \
      '--format=json(result.macAddress,result.lacpStatus,result.links)' \
      --quiet
    ;;
  *)
    echo "unsupported networking operation" >&2
    exit 2
    ;;
esac
