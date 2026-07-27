import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CANARY = "packtest-canary-gcp-lb-secret-c3a7"


def backend():
    return {
        "name": "harness-backend",
        "loadBalancingScheme": "EXTERNAL_MANAGED",
        "protocol": "HTTP",
        "portName": "http",
        "timeoutSec": 30,
        "healthChecks": ["global/healthChecks/harness-health"],
        "backends": [{
            "group": "zones/us-central1-a/networkEndpointGroups/harness-neg",
            "balancingMode": "RATE",
            "capacityScaler": 1,
        }],
        "iap": {"enabled": True, "oauth2ClientSecret": CANARY},
        "securitySettings": {"awsV4Authentication": {"accessKey": CANARY}},
        "customRequestHeaders": [f"X-Harness-Request: {CANARY}"],
        "customResponseHeaders": [f"X-Harness-Response: {CANARY}"],
        "description": CANARY,
    }


def response(path):
    if path == "/health":
        return {"ok": True}
    if "/getHealth" in path:
        return {
            "kind": "compute#backendServiceGroupHealth",
            "healthStatus": [{
                "healthState": "HEALTHY",
                "ipAddress": "10.20.0.10",
                "port": 8080,
                "annotations": {"note": "fixture"},
            }],
        }
    if "/global/backendServices/harness-backend" in path:
        return backend()
    if "/aggregated/backendServices" in path:
        return {"items": {"global": {"backendServices": [backend()]}}}
    if "/aggregated/healthChecks" in path:
        return {
            "items": {
                "global": {
                    "healthChecks": [{
                        "name": "harness-health",
                        "type": "HTTP",
                        "httpHealthCheck": {
                            "port": 8080,
                            "requestPath": "/readyz",
                            "response": CANARY,
                        },
                        "checkIntervalSec": 5,
                        "timeoutSec": 3,
                        "healthyThreshold": 2,
                        "unhealthyThreshold": 2,
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/aggregated/urlMaps" in path:
        return {
            "items": {
                "global": {
                    "urlMaps": [{
                        "name": "harness-map",
                        "defaultService": "global/backendServices/harness-backend",
                        "hostRules": [{"hosts": ["example.test"], "pathMatcher": "app"}],
                        "pathMatchers": [{
                            "name": "app",
                            "defaultService": "global/backendServices/harness-backend",
                            "pathRules": [{
                                "paths": ["/api/*"],
                                "service": "global/backendServices/harness-backend",
                            }],
                            "routeRules": [{
                                "priority": 10,
                                "service": "global/backendServices/harness-backend",
                                "headerAction": {
                                    "requestHeadersToAdd": [{
                                        "headerName": "X-Secret",
                                        "headerValue": CANARY,
                                    }]
                                },
                            }],
                            "headerAction": {
                                "responseHeadersToAdd": [{
                                    "headerName": "X-Secret",
                                    "headerValue": CANARY,
                                }]
                            },
                        }],
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/aggregated/targetHttpProxies" in path:
        return {
            "items": {
                "global": {
                    "targetHttpProxies": [{
                        "name": "harness-http",
                        "urlMap": "global/urlMaps/harness-map",
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/aggregated/targetHttpsProxies" in path:
        return {
            "items": {
                "global": {
                    "targetHttpsProxies": [{
                        "name": "harness-https",
                        "urlMap": "global/urlMaps/harness-map",
                        "sslCertificates": ["global/sslCertificates/harness-cert"],
                        "quicOverride": "ENABLE",
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/aggregated/forwardingRules" in path:
        return {
            "items": {
                "global": {
                    "forwardingRules": [{
                        "name": "harness-forwarding-rule",
                        "IPAddress": "203.0.113.20",
                        "IPProtocol": "TCP",
                        "portRange": "443-443",
                        "target": "global/targetHttpsProxies/harness-https",
                        "loadBalancingScheme": "EXTERNAL_MANAGED",
                        "description": CANARY,
                    }]
                }
            }
        }
    if "/aggregated/networkEndpointGroups" in path:
        return {
            "items": {
                "zones/us-central1-a": {
                    "networkEndpointGroups": [{
                        "name": "harness-neg",
                        "zone": "zones/us-central1-a",
                        "networkEndpointType": "GCE_VM_IP_PORT",
                        "defaultPort": 8080,
                        "size": 1,
                        "description": CANARY,
                    }]
                }
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
