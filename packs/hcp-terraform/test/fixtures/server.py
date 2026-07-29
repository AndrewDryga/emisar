import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

API_TOKEN = "packtest-canary-tfe-token-6d2a"
PLAN_SECRET = "packtest-canary-tfe-plan-secret-91c7"

ORGANIZATION = "example-corp"
WORKSPACE_ID = "ws-8Rp2nKcQvWxYzA1b"
RUN_ID = "run-4Qm7TvLpXsRbNc2d"
CREATED_RUN_ID = "run-9Zk3WdFyHnJqEr5t"

# One mutable run per server process. Every case owns a fresh Compose project,
# so apply/discard/cancel each start from the same planned run.
RUNS = {
    RUN_ID: {
        "status": "planned",
        "message": "Rotate the API instance",
        "plan-only": False,
        "confirmable": True,
        "discardable": True,
        "cancelable": True,
    }
}


def run_document(run_id):
    run = RUNS[run_id]
    return {
        "id": run_id,
        "type": "runs",
        "attributes": {
            "status": run["status"],
            "message": run["message"],
            "is-destroy": False,
            "plan-only": run["plan-only"],
            "has-changes": True,
            "source": "tfe-api",
            "created-at": "2026-07-28T12:00:00.000Z",
            "actions": {
                "is-confirmable": run["confirmable"],
                "is-discardable": run["discardable"],
                "is-cancelable": run["cancelable"],
            },
        },
        "relationships": {
            "workspace": {"data": {"id": WORKSPACE_ID, "type": "workspaces"}},
            "plan": {"data": {"id": "plan-Xt7bQ2mLvNc4Ra8s", "type": "plans"}},
        },
    }


def plan_document():
    return {
        "id": "plan-Xt7bQ2mLvNc4Ra8s",
        "type": "plans",
        "attributes": {
            "status": "finished",
            "has-changes": True,
            "resource-additions": 1,
            "resource-changes": 1,
            "resource-destructions": 2,
            "resource-imports": 0,
            "log-read-url": "https://archivist.example.test/plan-log",
        },
    }


def pagination(next_page=None):
    return {"pagination": {"current-page": 1, "next-page": next_page, "total-count": 1}}


# The structured plan HCP Terraform serves carries every value in cleartext, so
# the fixture puts the canary where a real plan puts a secret: in a sensitive
# output and in a resource attribute the projection must never read.
def plan_json_output():
    return {
        "format_version": "1.2",
        "terraform_version": "1.13.1",
        "resource_changes": [
            {
                "address": "aws_instance.api",
                "mode": "managed",
                "type": "aws_instance",
                "name": "api",
                "provider_name": "registry.terraform.io/hashicorp/aws",
                "change": {
                    "actions": ["delete", "create"],
                    "before": {"user_data": PLAN_SECRET},
                    "after": {"user_data": PLAN_SECRET},
                },
            },
            {
                "address": "module.db.aws_db_instance.main",
                "module_address": "module.db",
                "mode": "managed",
                "type": "aws_db_instance",
                "name": "main",
                "change": {
                    "actions": ["update"],
                    "before": {"password": PLAN_SECRET},
                    "after": {"password": PLAN_SECRET},
                },
            },
            {
                "address": "aws_s3_bucket.legacy",
                "mode": "managed",
                "type": "aws_s3_bucket",
                "name": "legacy",
                "action_reason": "delete_because_no_resource_config",
                "change": {"actions": ["delete"], "before": {}, "after": None},
            },
            {
                "address": "aws_iam_role.unchanged",
                "mode": "managed",
                "type": "aws_iam_role",
                "name": "unchanged",
                "change": {"actions": ["no-op"], "before": {}, "after": {}},
            },
        ],
        "resource_drift": [
            {
                "address": "aws_security_group.web",
                "mode": "managed",
                "type": "aws_security_group",
                "name": "web",
                "change": {"actions": ["update"], "before": {}, "after": {}},
            }
        ],
        "output_changes": {
            "db_password": {
                "actions": ["update"],
                "before": PLAN_SECRET,
                "after": PLAN_SECRET,
                "before_sensitive": True,
                "after_sensitive": True,
            },
            "endpoint": {
                "actions": ["create"],
                "before": None,
                "after": "api.example.test",
                "before_sensitive": False,
                "after_sensitive": False,
            },
            "stable": {
                "actions": ["no-op"],
                "before": "unchanged",
                "after": "unchanged",
                "before_sensitive": False,
                "after_sensitive": False,
            },
        },
    }


def get_response(path):
    if path == "/api/v2/organizations":
        return {
            "data": [{
                "id": ORGANIZATION,
                "type": "organizations",
                "attributes": {
                    "email": "platform@example.test",
                    "created-at": "2025-01-04T09:30:00.000Z",
                },
            }],
            "meta": pagination(),
        }
    if path == f"/api/v2/organizations/{ORGANIZATION}/workspaces":
        return {
            "data": [{
                "id": WORKSPACE_ID,
                "type": "workspaces",
                "attributes": {
                    "name": "production-network",
                    "execution-mode": "remote",
                    "terraform-version": "1.13.1",
                    "auto-apply": False,
                    "locked": True,
                    "resource-count": 47,
                    "updated-at": "2026-07-28T11:58:00.000Z",
                },
            }],
            "meta": pagination(next_page=2),
        }
    if path == f"/api/v2/workspaces/{WORKSPACE_ID}/runs":
        return {"data": [run_document(RUN_ID)], "meta": pagination()}
    for run_id in RUNS:
        if path == f"/api/v2/runs/{run_id}":
            return {"data": run_document(run_id), "included": [plan_document()]}
    return None


class Handler(BaseHTTPRequestHandler):
    def write_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/vnd.api+json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authenticated(self):
        if self.headers.get("Authorization") == f"Bearer {API_TOKEN}":
            return True
        self.write_json(401, {"errors": [{"title": "unauthorized"}]})
        return False

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self.write_json(200, {"ok": True})
            return
        # Unauthenticated on purpose: this is what packtest probes read to see
        # whether a mutation actually landed, and it stands in for the presigned
        # blob URL the real json-output endpoint redirects to.
        if path.startswith("/probe/runs/"):
            run_id = path.rsplit("/", 1)[-1]
            if run_id not in RUNS:
                self.write_json(404, {"errors": [{"title": "not found"}]})
                return
            self.write_json(200, {"status": RUNS[run_id]["status"]})
            return
        if path == "/blob/plan-json-output":
            self.write_json(200, plan_json_output())
            return
        if not self.authenticated():
            return
        if path == f"/api/v2/runs/{RUN_ID}/plan/json-output":
            self.send_response(307)
            self.send_header("Location", "/blob/plan-json-output")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        payload = get_response(path)
        if payload is None:
            self.write_json(404, {"errors": [{"title": "unexpected request"}]})
            return
        self.write_json(200, payload)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length) or b"{}")

    def do_POST(self):
        path = urlparse(self.path).path
        if not self.authenticated():
            return
        if self.headers.get("Content-Type") != "application/vnd.api+json":
            self.write_json(415, {"errors": [{"title": "unsupported media type"}]})
            return
        body = self.read_body()

        if path == "/api/v2/runs":
            data = body.get("data", {})
            workspace = data.get("relationships", {}).get("workspace", {}).get("data", {})
            if data.get("attributes", {}).get("plan-only") is not True:
                self.write_json(422, {"errors": [{"title": "expected a plan-only run"}]})
                return
            if workspace.get("id") != WORKSPACE_ID:
                self.write_json(404, {"errors": [{"title": "unknown workspace"}]})
                return
            RUNS[CREATED_RUN_ID] = {
                "status": "pending",
                "message": data["attributes"].get("message", ""),
                "plan-only": True,
                "confirmable": False,
                "discardable": False,
                "cancelable": True,
            }
            self.write_json(201, {"data": run_document(CREATED_RUN_ID)})
            return

        transitions = {"apply": "applying", "discard": "discarded", "cancel": "canceled"}
        for verb, status in transitions.items():
            if path == f"/api/v2/runs/{RUN_ID}/actions/{verb}":
                run = RUNS[RUN_ID]
                if verb == "apply" and not run["confirmable"]:
                    self.write_json(409, {"errors": [{"title": "run is not confirmable"}]})
                    return
                run["status"] = status
                run["confirmable"] = False
                run["discardable"] = False
                run["cancelable"] = verb == "apply"
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

        self.write_json(404, {"errors": [{"title": "unexpected request"}]})

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
