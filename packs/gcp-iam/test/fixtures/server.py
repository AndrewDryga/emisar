import json
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
        projects = projects_response(self.path, self.headers)
        if projects is not None:
            status, payload = projects
        else:
            payload = response(self.path)
            status = 200 if payload is not None else 404
        body = json.dumps(payload if payload is not None else {
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
