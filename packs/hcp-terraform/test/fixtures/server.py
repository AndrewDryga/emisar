import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

API_TOKEN = "packtest-canary-tfe-token-6d2a"
PLAN_SECRET = "packtest-canary-tfe-plan-secret-91c7"
# Stands in for the signature of a presigned archivist log URL: the actions
# fetch through it but must never let it reach stdout, stderr, or the audit.
LOG_URL_SIGNATURE = "packtest-canary-tfe-log-signature-4b9e"

ORGANIZATION = "example-corp"
WORKSPACE_ID = "ws-8Rp2nKcQvWxYzA1b"
CONFIGURATION_VERSION_ID = "cv-6JmJpQnRsTuVwX2y"
RUN_ID = "run-4Qm7TvLpXsRbNc2d"
CREATED_RUN_ID = "run-9Zk3WdFyHnJqEr5t"
RETRY_RUN_ID = "run-7Xb5RetryNpQw3Ke"
PLAN_ERRORED_RUN_ID = "run-2PlanErrVt8Kq5Wd"
APPLY_ERRORED_RUN_ID = "run-3ApplyErrJn6Rt4c"
LOGLESS_RUN_ID = "run-5NoLogWp4Hs2Ym8q"
DENIED_LOG_RUN_ID = "run-6DeniedBv1Zx7Qf3"
CANCELED_NO_CV_RUN_ID = "run-8NoCvFh9Kl4Tq6wY"
GLOB_LOG_RUN_ID = "run-9GlobUrlYz2Bc5Df"

# One mutable run table per server process. Every case owns a fresh Compose
# project, so mutations always start from the same fixture state; the errored
# rows are read-only diagnostics subjects and RETRY_RUN_ID / CREATED_RUN_ID
# appear once the matching POST lands. A phase's "log-path" becomes a
# host-derived presigned log-read-url; a phase without one models HCP
# returning no log at all.
RUNS = {
    RUN_ID: {
        "status": "planned",
        "message": "Rotate the API instance",
        "plan-only": False,
        "confirmable": True,
        "discardable": True,
        "cancelable": True,
        "configuration-version": CONFIGURATION_VERSION_ID,
        "plan": {
            "id": "plan-Xt7bQ2mLvNc4Ra8s",
            "status": "finished",
            "has-changes": True,
            "resource-additions": 1,
            "resource-changes": 1,
            "resource-destructions": 2,
            "resource-imports": 0,
            "log-path": "/blob/logs/finished-plan",
        },
    },
    PLAN_ERRORED_RUN_ID: {
        "status": "errored",
        "message": "Nightly baseline",
        "plan-only": False,
        "confirmable": False,
        "discardable": False,
        "cancelable": False,
        "configuration-version": CONFIGURATION_VERSION_ID,
        "plan": {
            "id": "plan-2ErrLmNoPqRs4Tu6",
            "status": "errored",
            "status-timestamps": {
                "started-at": "2026-07-30T02:11:04+00:00",
                "errored-at": "2026-07-30T02:12:31+00:00",
            },
            "log-path": "/blob/logs/errored-plan",
        },
        "apply": {"id": "apply-2UnreachVw8Xy1Za", "status": "unreachable"},
    },
    APPLY_ERRORED_RUN_ID: {
        "status": "errored",
        "message": "Resize the database",
        "plan-only": False,
        "confirmable": False,
        "discardable": False,
        "cancelable": False,
        "configuration-version": CONFIGURATION_VERSION_ID,
        "plan": {
            "id": "plan-3FinishedAb5Cd7E",
            "status": "finished",
            "status-timestamps": {
                "started-at": "2026-07-29T09:40:12+00:00",
                "finished-at": "2026-07-29T09:41:55+00:00",
            },
            "log-path": "/blob/logs/finished-plan",
        },
        "apply": {
            "id": "apply-3ErrFg9Hi2Jk4Lm",
            "status": "errored",
            "status-timestamps": {
                "started-at": "2026-07-29T09:45:03+00:00",
                "errored-at": "2026-07-29T10:02:47+00:00",
            },
            "log-path": "/blob/logs/errored-apply",
        },
    },
    LOGLESS_RUN_ID: {
        "status": "errored",
        "message": "Expired before logging",
        "plan-only": False,
        "confirmable": False,
        "discardable": False,
        "cancelable": False,
        "configuration-version": CONFIGURATION_VERSION_ID,
        "plan": {
            "id": "plan-5NoLogNp6Qr8St1U",
            "status": "errored",
            "status-timestamps": {
                "started-at": "2026-07-27T14:03:20+00:00",
                "errored-at": "2026-07-27T14:03:22+00:00",
            },
        },
    },
    DENIED_LOG_RUN_ID: {
        "status": "errored",
        "message": "Log retention lapsed",
        "plan-only": False,
        "confirmable": False,
        "discardable": False,
        "cancelable": False,
        "configuration-version": CONFIGURATION_VERSION_ID,
        "plan": {
            "id": "plan-6DeniedVw3Xy5Za7",
            "status": "errored",
            "status-timestamps": {
                "started-at": "2026-07-26T08:15:00+00:00",
                "errored-at": "2026-07-26T08:16:41+00:00",
            },
            "log-path": "/blob/logs/denied",
        },
    },
    # curl expands {a,b} in a URL into one transfer per alternative, so an API
    # answering with a braced host list would hand the presigned signature to a
    # host of its choosing. The second alternative is this same fixture, which
    # would happily serve a log — so only rejecting the URL keeps it unread.
    GLOB_LOG_RUN_ID: {
        "status": "errored",
        "message": "Log URL smuggles a second host",
        "plan-only": False,
        "confirmable": False,
        "discardable": False,
        "cancelable": False,
        "configuration-version": CONFIGURATION_VERSION_ID,
        "plan": {
            "id": "plan-9GlobFg2Hj5Kl7Mn",
            "status": "errored",
            "status-timestamps": {
                "started-at": "2026-07-24T11:00:00+00:00",
                "errored-at": "2026-07-24T11:01:12+00:00",
            },
            "log-url-override": "http://{tfc-api,tfc-api}:8080/blob/logs/errored-plan",
        },
    },
    CANCELED_NO_CV_RUN_ID: {
        "status": "canceled",
        "message": "CLI-driven run without a configuration version",
        "plan-only": False,
        "confirmable": False,
        "discardable": False,
        "cancelable": False,
        "configuration-version": None,
        "plan": {
            "id": "plan-8CanceledBc4De6F",
            "status": "canceled",
            "status-timestamps": {
                "started-at": "2026-07-25T19:22:10+00:00",
                "canceled-at": "2026-07-25T19:24:05+00:00",
            },
            "log-path": "/blob/logs/finished-plan",
        },
    },
}


def run_document(run_id):
    run = RUNS[run_id]
    relationships = {
        "workspace": {"data": {"id": WORKSPACE_ID, "type": "workspaces"}},
    }
    if run.get("configuration-version"):
        relationships["configuration-version"] = {
            "data": {"id": run["configuration-version"], "type": "configuration-versions"}
        }
    for kind, jsonapi_type in (("plan", "plans"), ("apply", "applies")):
        if kind in run:
            relationships[kind] = {"data": {"id": run[kind]["id"], "type": jsonapi_type}}
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
        "relationships": relationships,
    }


def phase_documents(run_id, host):
    run = RUNS[run_id]
    docs = []
    for kind, jsonapi_type in (("plan", "plans"), ("apply", "applies")):
        if kind not in run:
            continue
        attributes = {
            k: v for k, v in run[kind].items()
            if k not in ("id", "log-path", "log-url-override")
        }
        if "log-url-override" in run[kind]:
            attributes["log-read-url"] = (
                f"{run[kind]['log-url-override']}?signature={LOG_URL_SIGNATURE}"
            )
        elif "log-path" in run[kind]:
            attributes["log-read-url"] = (
                f"http://{host}{run[kind]['log-path']}?signature={LOG_URL_SIGNATURE}"
            )
        docs.append({"id": run[kind]["id"], "type": jsonapi_type, "attributes": attributes})
    return docs


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


# 300 refresh lines push the error past the action's 200-line tail window, so
# the case can prove the bound: early noise is dropped, the error survives.
# ANSI codes wrap the error exactly the way terraform colors its output.
def plan_error_log():
    lines = [f"aws_instance.api: Refreshing state... refresh line {n}" for n in range(1, 301)]
    lines += [
        "\x1b[31m\x1b[1mError: creating S3 Bucket (emisar-legacy): AccessDenied\x1b[0m",
        "",
        "\x1b[31m  with aws_s3_bucket.legacy,\x1b[0m",
        '  on buckets.tf line 12, in resource "aws_s3_bucket" "legacy":',
    ]
    return "\n".join(lines) + "\n"


def apply_error_log():
    return (
        "module.db.aws_db_instance.main: Modifying... [id=emisar-db]\n"
        "\x1b[31mError: updating RDS DB Instance (emisar-db): timeout while waiting for state\x1b[0m\n"
        "\x1b[0m\x1b[1mApply errored after 17m44s\x1b[0m\n"
    )


def finished_plan_log():
    return "Plan: 1 to add, 1 to change, 2 to destroy.\n"


LOG_BLOBS = {
    "/blob/logs/errored-plan": plan_error_log,
    "/blob/logs/errored-apply": apply_error_log,
    "/blob/logs/finished-plan": finished_plan_log,
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
    return None


class Handler(BaseHTTPRequestHandler):
    def write_json(self, status, payload):
        self.write_bytes(status, "application/vnd.api+json", json.dumps(payload).encode())

    def write_bytes(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
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
        # whether a mutation actually landed and what it pinned.
        if path.startswith("/probe/runs/"):
            run_id = path.rsplit("/", 1)[-1]
            if run_id not in RUNS:
                self.write_json(404, {"errors": [{"title": "not found"}]})
                return
            run = RUNS[run_id]
            self.write_json(200, {
                "status": run["status"],
                "plan-only": run["plan-only"],
                "auto-apply": run.get("auto-apply"),
                "configuration-version": run.get("configuration-version"),
            })
            return
        # The blob endpoints stand in for presigned archivist URLs, so they are
        # unauthenticated too; /blob/logs/denied models a signature HCP no
        # longer honors.
        if path == "/blob/logs/denied":
            self.write_json(403, {"errors": [{"title": "forbidden"}]})
            return
        if path in LOG_BLOBS:
            self.write_bytes(200, "text/plain", LOG_BLOBS[path]().encode())
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
        host = self.headers.get("Host", "tfc-api:8080")
        for run_id in RUNS:
            if path == f"/api/v2/runs/{run_id}":
                self.write_json(200, {
                    "data": run_document(run_id),
                    "included": phase_documents(run_id, host),
                })
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
            attributes = data.get("attributes", {})
            relationships = data.get("relationships", {})
            workspace = relationships.get("workspace", {}).get("data", {})
            if workspace.get("id") != WORKSPACE_ID:
                self.write_json(404, {"errors": [{"title": "unknown workspace"}]})
                return
            if attributes.get("plan-only") is True:
                RUNS[CREATED_RUN_ID] = {
                    "status": "pending",
                    "message": attributes.get("message", ""),
                    "plan-only": True,
                    "confirmable": False,
                    "discardable": False,
                    "cancelable": True,
                    "configuration-version": CONFIGURATION_VERSION_ID,
                }
                self.write_json(201, {"data": run_document(CREATED_RUN_ID)})
                return
            # A standard run must state both safety gates explicitly: the
            # retry contract sends plan-only false AND auto-apply false,
            # never a workspace default.
            if attributes.get("plan-only") is not False or attributes.get("auto-apply") is not False:
                self.write_json(422, {"errors": [{"title": "expected explicit plan-only and auto-apply false"}]})
                return
            configuration_version = relationships.get("configuration-version", {}).get("data", {})
            if configuration_version.get("id") != CONFIGURATION_VERSION_ID:
                self.write_json(422, {"errors": [{"title": "unknown configuration version"}]})
                return
            RUNS[RETRY_RUN_ID] = {
                "status": "pending",
                "message": attributes.get("message", ""),
                "plan-only": False,
                "auto-apply": False,
                "confirmable": False,
                "discardable": False,
                "cancelable": True,
                "configuration-version": CONFIGURATION_VERSION_ID,
            }
            self.write_json(201, {"data": run_document(RETRY_RUN_ID)})
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
