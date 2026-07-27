import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CANARY = "packtest-canary-gcp-certificate-secret-1f4b"


def legacy_certificate():
    return {
        "name": "harness-legacy-cert",
        "type": "MANAGED",
        "managed": {"domains": ["example.test"], "status": "ACTIVE"},
        "subjectAlternativeNames": ["example.test"],
        "expireTime": "2027-07-27T00:00:00Z",
        "certificate": f"-----BEGIN CERTIFICATE-----{CANARY}",
        "privateKey": CANARY,
        "description": CANARY,
    }


def managed_certificate():
    return {
        "name": "projects/example-prod/locations/global/certificates/harness-managed-cert",
        "scope": "DEFAULT",
        "sanDnsnames": ["example.test"],
        "managed": {
            "domains": ["example.test"],
            "state": "ACTIVE",
            "authorizationAttemptInfo": [{
                "domain": "example.test",
                "state": "AUTHORIZED",
            }],
        },
        "selfManaged": {
            "pemCertificate": f"-----BEGIN CERTIFICATE-----{CANARY}",
            "pemPrivateKey": CANARY,
        },
        "description": CANARY,
        "labels": {"secret": CANARY},
        "expireTime": "2027-07-27T00:00:00Z",
    }


def response(path):
    if path == "/health":
        return {"ok": True}
    if "/global/sslCertificates/harness-legacy-cert" in path:
        return legacy_certificate()
    if "/aggregated/sslCertificates" in path:
        return {
            "items": {
                "global": {
                    "sslCertificates": [legacy_certificate()]
                }
            }
        }
    if "/certificates/harness-managed-cert" in path:
        return managed_certificate()
    if path.startswith("/v1/projects/example-prod/locations/global/certificates"):
        return {"certificates": [managed_certificate()]}
    if "/certificateMaps/harness-map/certificateMapEntries" in path:
        return {
            "certificateMapEntries": [{
                "name": "projects/example-prod/locations/global/certificateMaps/harness-map/certificateMapEntries/harness-entry",
                "hostname": "example.test",
                "certificates": [
                    "projects/example-prod/locations/global/certificates/harness-managed-cert"
                ],
                "state": "ACTIVE",
                "description": CANARY,
            }]
        }
    if path.startswith("/v1/projects/example-prod/locations/global/certificateMaps"):
        return {
            "certificateMaps": [{
                "name": "projects/example-prod/locations/global/certificateMaps/harness-map",
                "gclbTargets": [{
                    "targetHttpsProxy": "projects/example-prod/global/targetHttpsProxies/harness-https"
                }],
                "description": CANARY,
                "labels": {"secret": CANARY},
            }]
        }
    if path.startswith("/v1/projects/example-prod/locations/global/dnsAuthorizations"):
        return {
            "dnsAuthorizations": [{
                "name": "projects/example-prod/locations/global/dnsAuthorizations/harness-authorization",
                "domain": "example.test",
                "type": "FIXED_RECORD",
                "dnsResourceRecord": {
                    "name": "_acme-challenge.example.test.",
                    "type": "CNAME",
                    "data": "validation.example.test.",
                },
                "description": CANARY,
                "labels": {"secret": CANARY},
            }]
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
