import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CANARY = "packtest-canary-gcp-network-secret-91af"


def response(path):
    if path == "/health":
        return {"ok": True}
    if "/global/networks/harness-network" in path:
        return {
            "name": "harness-network",
            "autoCreateSubnetworks": False,
            "mtu": 1460,
            "routingConfig": {"routingMode": "GLOBAL"},
            "subnetworks": ["regions/us-central1/subnetworks/harness-subnet"],
            "peerings": [{
                "name": "harness-peer",
                "network": "projects/peer/global/networks/peer",
                "state": "ACTIVE",
                "exchangeSubnetRoutes": True,
            }],
            "description": CANARY,
        }
    if path.startswith("/compute/v1/projects/example-prod/global/networks"):
        return {
            "items": [{
                "name": "harness-network",
                "autoCreateSubnetworks": False,
                "mtu": 1460,
                "routingConfig": {"routingMode": "CUSTOM"},
                "description": CANARY,
            }]
        }
    if "/regions/us-central1/subnetworks/harness-subnet" in path:
        return {
            "name": "harness-subnet",
            "region": "regions/us-central1",
            "network": "global/networks/harness-network",
            "ipCidrRange": "10.20.0.0/24",
            "stackType": "IPV4_ONLY",
            "privateIpGoogleAccess": True,
            "description": CANARY,
        }
    if "/aggregated/subnetworks" in path:
        return {
            "items": {
                "regions/us-central1": {
                    "subnetworks": [{
                        "name": "harness-subnet",
                        "region": "regions/us-central1",
                        "network": "global/networks/harness-network",
                        "ipCidrRange": "10.20.0.0/24",
                        "stackType": "IPV4_ONLY",
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/global/firewalls" in path:
        return {
            "items": [{
                "name": "harness-https",
                "network": "global/networks/harness-network",
                "direction": "INGRESS",
                "priority": 1000,
                "allowed": [{"IPProtocol": "tcp", "ports": ["443"]}],
                "description": CANARY,
            }]
        }
    if "/global/routes" in path:
        return {
            "items": [{
                "name": "harness-default-route",
                "network": "global/networks/harness-network",
                "destRange": "0.0.0.0/0",
                "priority": 1000,
                "nextHopGateway": "global/gateways/default-internet-gateway",
                "description": CANARY,
            }]
        }
    if "/aggregated/addresses" in path:
        return {
            "items": {
                "regions/us-central1": {
                    "addresses": [{
                        "name": "harness-address",
                        "address": "203.0.113.10",
                        "addressType": "EXTERNAL",
                        "status": "IN_USE",
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/getRouterStatus" in path:
        return {
            "result": {
                "bgpPeerStatus": [{"name": "harness-peer", "status": "UP"}],
                "bestRoutes": [{"destRange": "10.30.0.0/16", "routeType": "BGP"}],
            }
        }
    if "/regions/us-central1/routers/harness-router" in path:
        return {
            "name": "harness-router",
            "region": "regions/us-central1",
            "network": "global/networks/harness-network",
            "bgp": {"asn": 64514, "advertiseMode": "DEFAULT"},
            "nats": [{
                "name": "harness-nat",
                "natIpAllocateOption": "AUTO_ONLY",
                "sourceSubnetworkIpRangesToNat": "ALL_SUBNETWORKS_ALL_IP_RANGES",
                "description": CANARY,
            }],
            "description": CANARY,
        }
    if "/aggregated/routers" in path:
        return {
            "items": {
                "regions/us-central1": {
                    "routers": [{
                        "name": "harness-router",
                        "region": "regions/us-central1",
                        "network": "global/networks/harness-network",
                        "bgp": {"asn": 64514, "advertiseMode": "DEFAULT"},
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/aggregated/vpnTunnels" in path:
        return {
            "items": {
                "regions/us-central1": {
                    "vpnTunnels": [{
                        "name": "harness-tunnel",
                        "region": "regions/us-central1",
                        "status": "ESTABLISHED",
                        "peerIp": "198.51.100.10",
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/getStatus" in path and "/vpnGateways/" in path:
        return {
            "result": {
                "vpnConnections": [{
                    "peerExternalGateway": "global/externalVpnGateways/harness-peer",
                    "state": {"state": "CONNECTION_REDUNDANCY_MET"},
                    "tunnels": [{"tunnelUrl": "regions/us-central1/vpnTunnels/harness-tunnel"}],
                }]
            }
        }
    if "/aggregated/interconnectAttachments" in path:
        return {
            "items": {
                "regions/us-central1": {
                    "interconnectAttachments": [{
                        "name": "harness-attachment",
                        "region": "regions/us-central1",
                        "state": "ACTIVE",
                        "bandwidth": "BPS_10G",
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/getDiagnostics" in path:
        return {
            "result": {
                "macAddress": "00:11:22:33:44:55",
                "lacpStatus": {"state": "ACTIVE"},
                "links": [{"name": "harness-link", "operationalStatus": "ACTIVE"}],
                "description": CANARY,
            }
        }
    return {"error": {"code": 404, "message": f"unhandled path {path}"}}


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        payload = response(self.path)
        status = 404 if "error" in payload else 200
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = handle_request
    do_POST = handle_request

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
