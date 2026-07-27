import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CANARY = "packtest-canary-gcp-dns-secret-b521"


def zone():
    return {
        "name": "harness-zone",
        "dnsName": "example.test.",
        "visibility": "public",
        "nameServers": ["ns-cloud-a1.googledomains.com."],
        "dnssecConfig": {"state": "on"},
        "description": CANARY,
        "labels": {"secret": CANARY},
    }


def response(path):
    if path == "/health":
        return {"ok": True}
    if "/managedZones/harness-zone/rrsets" in path:
        return {
            "rrsets": [{
                "name": "api.example.test.",
                "type": "A",
                "ttl": 300,
                "rrdatas": ["203.0.113.30"],
            }]
        }
    if "/managedZones/harness-zone" in path:
        return zone()
    if "/managedZones" in path:
        return {"managedZones": [zone()]}
    if "/responsePolicies/harness-response/rules" in path:
        return {
            "responsePolicyRules": [{
                "ruleName": "harness-rule",
                "dnsName": "blocked.example.test.",
                "behavior": "NXDOMAIN",
                "description": CANARY,
            }]
        }
    if "/responsePolicies" in path:
        return {
            "responsePolicies": [{
                "responsePolicyName": "harness-response",
                "networks": [{
                    "networkUrl": "projects/example-prod/global/networks/harness-network"
                }],
                "description": CANARY,
            }]
        }
    if "/policies" in path:
        return {
            "policies": [{
                "name": "harness-policy",
                "enableLogging": True,
                "networks": [{
                    "networkUrl": "projects/example-prod/global/networks/harness-network"
                }],
                "alternativeNameServerConfig": {
                    "targetNameServers": [{
                        "ipv4Address": "10.20.0.53",
                        "forwardingPath": "private",
                    }]
                },
                "description": CANARY,
            }]
        }
    return {"error": {"code": 404, "message": f"unhandled path {path}"}}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = response(self.path)
        status = 404 if "error" in payload else 200
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
