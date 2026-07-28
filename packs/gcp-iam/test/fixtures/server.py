import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def pool():
    return {
        "name": (
            "projects/1001/locations/global/"
            "workloadIdentityPools/harness-pool"
        ),
        "displayName": "Harness pool",
        "description": "Harness automation identities",
        "state": "ACTIVE",
        "disabled": False,
    }


def provider():
    return {
        "name": (
            "projects/1001/locations/global/workloadIdentityPools/"
            "harness-pool/providers/harness-provider"
        ),
        "displayName": "Harness provider",
        "description": "Harness OIDC provider",
        "state": "ACTIVE",
        "disabled": False,
        "attributeMapping": {
            "google.subject": "assertion.sub",
            "attribute.repository": "assertion.repository",
        },
        "attributeCondition": (
            "assertion.repository_owner == 'example'"
        ),
        "oidc": {
            "issuerUri": "https://issuer.example.test",
            "allowedAudiences": ["https://example.test/emisar"],
        },
    }


def response(path):
    path = urlparse(path).path
    if path == "/health":
        return {"ok": True}
    if path.endswith(
        "/workloadIdentityPools/harness-pool/providers/harness-provider"
    ):
        return provider()
    if path.endswith("/locations/global/workloadIdentityPools"):
        return {"workloadIdentityPools": [pool()]}
    if path.endswith(":getIamPolicy") and "/serviceAccounts/" in path:
        return {
            "version": 3,
            "etag": "BwYHARNESS==",
            "bindings": [{
                "role": "roles/iam.workloadIdentityUser",
                "members": [
                    "principalSet://iam.googleapis.com/projects/1001/"
                    "locations/global/workloadIdentityPools/harness-pool/*"
                ],
            }],
        }
    return None


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        payload = response(self.path)
        status = 200 if payload is not None else 404
        body = json.dumps(payload or {
            "error": {"code": 404, "message": f"unhandled path {self.path}"}
        }).encode()
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
