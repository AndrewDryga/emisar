import json
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def project(project_id, number, name):
    return {
        "projectId": project_id,
        "projectNumber": str(number),
        "name": name,
        "lifecycleState": "ACTIVE",
        "labels": {"internal": "private-fixture-label"},
        "createTime": "2026-01-01T00:00:00Z",
    }


def projects_response(path, headers):
    url = urlparse(path)
    if not url.path.endswith("/v1/projects"):
        return None
    if headers.get("Authorization") != (
        "Bearer packtest-canary-gcp-iam-access-token-093f"
    ) or url.path.startswith("/unauthenticated/"):
        return 401, {"error": {
            "code": 401, "status": "UNAUTHENTICATED",
            "message": "UNAUTHENTICATED: authentication required",
        }}
    if url.path.startswith("/denied/"):
        return 403, {"error": {
            "code": 403, "status": "PERMISSION_DENIED",
            "message": "PERMISSION_DENIED: project discovery denied",
        }}
    query = parse_qs(url.query)
    page_size = int(query.get("pageSize", ["0"])[0])
    if query.get("filter") != ["lifecycleState:ACTIVE"] or not 1 <= page_size <= 500:
        return 400, {"error": {"code": 400, "message": "invalid project query"}}
    if url.path == "/empty/v1/projects":
        return 200, {}
    if url.path == "/large/v1/projects":
        items = [
            project(f"fixture-project-{i:03}", 100000000000 + i, "X" * 30)
            for i in range(501)
        ]
    elif url.path == "/v1/projects":
        items = [
            project("example-prod", 1001, "Example production"),
            project("example-staging", 1002, "Example staging"),
        ]
    else:
        return 404, {"error": {"code": 404, "message": "unknown project path"}}
    cursor = query.get("pageToken", ["page-0"])[0]
    offset = int(cursor.removeprefix("page-"))
    # Deliberately return short pages so the real CLI must follow nextPageToken.
    end = min(offset + page_size, offset + 250 if len(items) > 2 else offset + 1)
    payload = {"projects": items[offset:end]}
    if end < len(items):
        payload["nextPageToken"] = f"page-{end}"
    return 200, payload


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
        if self.path == "/v3/iam:troubleshoot":
            status, payload = self.troubleshoot()
            projects = None
        else:
            projects = projects_response(self.path, self.headers)
        if self.path == "/v3/iam:troubleshoot":
            pass
        elif projects is not None:
            status, payload = projects
        else:
            payload = response(self.path)
            status = 200 if payload is not None else 404
        body = json.dumps(payload if payload is not None else {
            "error": {"code": 404, "message": f"unhandled path {self.path}"}
        }).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if not (self.path == "/v3/iam:troubleshoot" and len(body) > 1048576):
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def troubleshoot(self):
        if self.command != "POST" or self.headers.get("Authorization") != (
            "Bearer packtest-canary-gcp-iam-access-token-093f"
        ):
            return 401, {"error": {"code": 401, "status": "UNAUTHENTICATED"}}
        if self.headers.get("x-goog-user-project") != "example-prod":
            return 400, {"error": {"code": 400, "message": "missing quota project"}}
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        access = request.get("accessTuple", {})
        if (set(request) != {"accessTuple"}
                or access.get("permission") != "bigquery.tables.create"
                or access.get("fullResourceName") != "//bigquery.googleapis.com/projects/example-prod/datasets/prod_modeled"):
            return 400, {"error": {"code": 400, "message": "invalid access tuple"}}
        principal = access.get("principal", "")
        if principal == "api-denied@example.com":
            return 403, {"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "Policy inspection denied"}}
        if principal == "oversized@example.com":
            return 200, {"overallAccessState": "CAN_ACCESS", "padding": "x" * 1100000}
        if principal == "malformed@example.com":
            return 200, {"unrelated": True}
        context = access.get("conditionContext", {})
        expected_resource = {
            "name": "projects/example-prod/datasets/prod_modeled",
            "service": "bigquery.googleapis.com", "type": "bigquery.googleapis.com/Dataset",
        }
        condition = context.get("resource") == expected_resource if context.get("resource") else None
        state = "CAN_ACCESS" if condition else "UNKNOWN_CONDITIONAL" if condition is None else "CANNOT_ACCESS"
        allow = "ALLOW_ACCESS_STATE_GRANTED" if condition else "ALLOW_ACCESS_STATE_UNKNOWN_CONDITIONAL" if condition is None else "ALLOW_ACCESS_STATE_NOT_GRANTED"
        if principal == "denied@example.com":
            state, allow = "CANNOT_ACCESS", "ALLOW_ACCESS_STATE_NOT_GRANTED"
        if principal == "unknown@example.com":
            state = "UNKNOWN_INFO"
        if principal == "context@example.com" and context != {
            "resource": expected_resource,
            "request": {"receiveTime": "2026-11-19T12:00:00Z"},
            "destination": {"ip": "2001:db8::1", "port": "443"},
        }:
            return 400, {"error": {"code": 400, "message": "missing conditional context"}}
        if principal == "deny-policy@example.com":
            state = "CANNOT_ACCESS"
        return 200, {
            "overallAccessState": state, "accessTuple": access,
            "allowPolicyExplanation": {
                "allowAccessState": allow,
                "explainedPolicies": [{
                    "fullResourceName": "//cloudresourcemanager.googleapis.com/projects/example-prod",
                    "bindingExplanations": [{
                        "role": "roles/bigquery.dataEditor",
                        "condition": {"expression": "resource.name.startsWith('projects/example-prod/datasets/prod_')"},
                        "conditionExplanation": {"value": condition, "errors": [{"code": 3, "message": "resource context missing"}] if condition is None else []},
                    }],
                }],
            },
            "denyPolicyExplanation": {"denyAccessState": "DENY_ACCESS_STATE_DENIED" if principal == "deny-policy@example.com" else "DENY_ACCESS_STATE_UNKNOWN_INFO" if principal == "unknown@example.com" else "DENY_ACCESS_STATE_NOT_DENIED"},
        }

    do_GET = handle_request
    do_POST = handle_request

    def log_message(self, fmt, *args):
        pass


https = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
https.socket = context.wrap_socket(https.socket, server_side=True)
threading.Thread(target=https.serve_forever, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
