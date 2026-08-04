import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_TOKEN = "packtest-canary-tfe-token-6d2a"
PLAN_SECRET = "packtest-canary-tfe-plan-secret-91c7"
# Stands in for the signature of a presigned archivist log URL: the actions
# fetch through it but must never let it reach stdout, stderr, or the audit.
LOG_URL_SIGNATURE = "packtest-canary-tfe-log-signature-4b9e"

ORGANIZATION = "example-corp"
MEGA_ORGANIZATION = "example-mega-corp"
WORKSPACE_ID = "ws-8Rp2nKcQvWxYzA1b"
WORST_WORKSPACE_ID = "ws-MaxPageWyXz9Qb7c"
UNIFORM_WORST_WORKSPACE_ID = "ws-AllWorstZq3Vf8Xk"
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
WORST_TAIL_RUN_ID = "run-1TailFloodMx9Kd4Ws"
WORST_PLAN_RUN_ID = "run-HugePlanWorstCase"
MALFORMED_PLAN_RUN_ID = "run-MalformedPlanDoc"
FUTURE_FORMAT_PLAN_RUN_ID = "run-FutureFormatPlan"

# Every codepoint of this message costs six bytes once JSON-escaped — the
# single most expensive shape the clip can emit. A page (or a diagnosed run)
# where every row carries it exercises the calculated worst case, not just a
# mixed sample.
UNIFORM_WORST_MESSAGE = "\u2028" * 60

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
    # The diagnostics worst case: the log floods the tail window with invalid
    # UTF-8 (the worst raw-to-encoded expansion — jq replaces each such byte
    # with three-byte U+FFFD) and the message floods the clip, so one run
    # exercises every bound of the structured result at once.
    WORST_TAIL_RUN_ID: {
        "status": "errored",
        "message": UNIFORM_WORST_MESSAGE,
        "plan-only": False,
        "confirmable": False,
        "discardable": False,
        "cancelable": False,
        "configuration-version": CONFIGURATION_VERSION_ID,
        "plan": {
            "id": "plan-1TailFloodQr7St2U",
            "status": "errored",
            "status-timestamps": {
                "started-at": "2026-07-31T05:30:00+00:00",
                "errored-at": "2026-07-31T05:47:19+00:00",
            },
            "log-path": "/blob/logs/worst-case-flood",
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


# The messages a real workspace accumulates: whole CI commit lines, floods of
# the characters JSON escaping doubles (backslash, quote, U+2028), multibyte
# text, and raw ANSI/control bytes. The worst-page cases list these at the
# maximum advertised page_size to prove the projected page stays inside the
# runner's 8 KiB structured-output cap.
WORST_MESSAGES = [
    "Merge pull request #4821 from blitz/renovate/major-terraform-google-modules " + "a" * 400,
    "\\" * 300,
    '"' * 300,
    " " * 200,
    "\U0001f680" * 150,
    "部署基础设施变更并轮换生产环境的API密钥" * 10,
    "deploy:\x1b[31m red \x07bell\x00null\ttab\nline2\x7f\x85del c1\nline3" + "x" * 200,
    "Rotate the API instance",
] + [
    f"ci: bump module versions and rotate credentials for stack {n} " + "long trailing commit body " * 20
    for n in range(4)
]


def worst_run_document(index, message, workspace_id=WORST_WORKSPACE_ID):
    return {
        "id": f"run-Worst{index:011d}",
        "type": "runs",
        "attributes": {
            "status": "planned_and_finished",
            "message": message,
            "is-destroy": False,
            "plan-only": False,
            "has-changes": True,
            "source": "tfe-configuration-version",
            "created-at": "2026-07-28T12:00:00.000Z",
            "actions": {
                "is-confirmable": False,
                "is-discardable": True,
                "is-cancelable": False,
            },
        },
        "relationships": {"workspace": {"data": {"id": workspace_id, "type": "workspaces"}}},
    }


def mega_workspace_document(index):
    name = f"platform-network-segment-{index:02d}-" + "x" * 62
    return {
        "id": f"ws-MegaCorp{index:08d}",
        "type": "workspaces",
        "attributes": {
            "name": name,
            "execution-mode": "remote",
            # TFE admins register custom Terraform versions under arbitrary
            # names; longer than the 64-codepoint clip on purpose.
            "terraform-version": "1.13.1-custom-enterprise-build-with-provider-mirror-2026-07-28-rc1",
            "auto-apply": False,
            "locked": True,
            "resource-count": 9999999,
            "updated-at": "2026-07-28T11:58:00.000Z",
        },
    }


def worst_organization_document(index):
    return {
        "id": f"mega-operations-team-{index:02d}",
        "type": "organizations",
        "attributes": {
            "email": f"team-{index:02d}-" + "operations-" * 21 + "contact@example.test",
            "created-at": "2025-01-04T09:30:00.000Z",
        },
    }


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


# A production-scale plan whose every field is hostile: hundreds of changes and
# drifted resources, addresses flooded with the byte JSON escaping doubles
# (backslash) and the codepoint whose escape costs six bytes (U+2028), types,
# modules, and reasons past every clip, and more outputs than the bounded
# sample keeps. The worst-case behavior case projects this plan; the runner
# rejects a structured result over 8 KiB, so the case's success is the
# byte-cap proof. The two sentinel deletes sort first (uppercase sorts before
# a backslash) and pin the exact clip boundary: 80 characters survive intact,
# 81 clip to 79 plus an ellipsis.
BACKSLASH_FLOOD = "\\" * 100
U2028_FLOOD = "\u2028" * 60
SENTINEL_KEEP_ADDRESS = "AAA-sentinel-delete-" + "x" * 60
SENTINEL_CLIP_ADDRESS = "AAB-sentinel-delete-" + "x" * 61


def worst_resource_change(address, actions, reason=None):
    change = {
        "address": address,
        "module_address": "module." + BACKSLASH_FLOOD,
        "mode": "managed",
        "type": "aws_" + BACKSLASH_FLOOD,
        "name": "worst",
        "change": {"actions": actions, "before": {}, "after": {}},
    }
    if reason is not None:
        change["action_reason"] = reason
    return change


def worst_plan_json_output():
    changes = [
        worst_resource_change(SENTINEL_KEEP_ADDRESS, ["delete"]),
        worst_resource_change(SENTINEL_CLIP_ADDRESS, ["delete"]),
    ]
    # The AAC deletes sort into the shown sample and keep U+2028 — whose escape
    # doubles a byte-bound value during the runner's canonical re-encode — in
    # the emitted result, not just in the dropped tail.
    changes += [
        worst_resource_change(f"AAC-{n:03d}-{U2028_FLOOD}", ["delete"], BACKSLASH_FLOOD)
        for n in range(4)
    ]
    changes += [
        worst_resource_change(f"{BACKSLASH_FLOOD}-{n:03d}", ["delete"], BACKSLASH_FLOOD)
        for n in range(114)
    ]
    changes += [
        worst_resource_change(f"{U2028_FLOOD}-{n:03d}", ["create", "delete"], BACKSLASH_FLOOD)
        for n in range(80)
    ]
    changes += [worst_resource_change(f"{BACKSLASH_FLOOD}-update-{n:03d}", ["update"]) for n in range(99)]
    changes += [worst_resource_change(f"{U2028_FLOOD}-create-{n:03d}", ["create"]) for n in range(80)]
    changes += [worst_resource_change(f"{BACKSLASH_FLOOD}-read-{n:03d}", ["read"]) for n in range(15)]
    changes += [worst_resource_change(f"{BACKSLASH_FLOOD}-import-{n:03d}", ["import"]) for n in range(5)]
    # A future CLI verb the projection has never seen: it must survive as a
    # joined, clipped action and still land in the total.
    changes.append(worst_resource_change("future-verb", ["provision", "refresh-only"]))
    changes += [worst_resource_change(f"noise-{n:03d}", ["no-op"]) for n in range(20)]
    outputs = {}
    for n in range(46):
        name = f"primary-database-connection-endpoint-{n:03d}-" + "x" * 20
        outputs[name] = {
            "actions": ["update"],
            "before_sensitive": n % 2 == 0,
            "after_sensitive": n % 2 == 0,
        }
    outputs[U2028_FLOOD] = {"actions": ["create"], "before_sensitive": False, "after_sensitive": False}
    outputs["stable-output"] = {"actions": ["no-op"], "before_sensitive": False, "after_sensitive": False}
    return {
        "format_version": "1.2",
        "terraform_version": "1.13.1-enterprise-worst-case-build-2026",
        "resource_changes": changes,
        "resource_drift": [
            worst_resource_change(f"{BACKSLASH_FLOOD}-drift-{n:03d}", ["update"]) for n in range(200)
        ],
        "output_changes": outputs,
    }


# A document that still reads back as a plan but carries a scalar where a
# collection belongs — what a truncating proxy or storage layer can return.
# The projection must refuse it: reading the collection with []? would report
# it as a plan with no changes.
def malformed_plan_json_output():
    return {
        "format_version": "1.2",
        "terraform_version": "1.13.1",
        "resource_changes": [],
        "resource_drift": "unavailable",
        "output_changes": {},
    }


# A document from a format major no released CLI emits. The JSON-format
# contract says a consumer must reject an unsupported major: a 2.x document
# could keep these collection types while changing what the members mean, so
# projecting it would report a truthful-looking summary of a plan whose
# semantics are unknown.
def future_format_plan_json_output():
    return {
        "format_version": "2.0",
        "terraform_version": "3.0.0",
        "resource_changes": [],
        "resource_drift": [],
        "output_changes": {},
    }


# 300 refresh lines push the error far past the action's 60-line / 2 KiB tail
# window, so the case can prove both bounds: early noise is dropped, the error
# survives. ANSI codes wrap the error exactly the way terraform colors its
# output.
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


# Bytes, not str: invalid UTF-8 cannot round-trip through a Python string.
# Every byte is invalid UTF-8, which jq replaces with three-byte U+FFFD — the
# worst raw-to-encoded expansion the tail pipeline can meet. 120 lines make
# the 60-line window bind first and the 2 KiB byte cap second, and the ASCII
# sentinel at the end proves the tail still ends with the line an operator
# diagnoses from.
def worst_case_flood_log():
    return (b"\xff" * 64 + b"\n") * 120 + b"Error: worst-case tail flood sentinel\n"


LOG_BLOBS = {
    "/blob/logs/errored-plan": plan_error_log,
    "/blob/logs/errored-apply": apply_error_log,
    "/blob/logs/finished-plan": finished_plan_log,
    "/blob/logs/worst-case-flood": worst_case_flood_log,
}


def get_response(path, query):
    page_size = int(query.get("page[size]", ["20"])[0])
    page = int(query.get("page[number]", ["1"])[0])
    if path == "/api/v2/organizations":
        # Page 2 is the maximal page: as many organizations as one request may
        # ask for, every contact email longer than the projection keeps. Page 3
        # is the uniform worst case: every email a flood of the most expensive
        # codepoint the clip can emit.
        if page == 2:
            return {
                "data": [worst_organization_document(n) for n in range(page_size)],
                "meta": pagination(next_page=3),
            }
        if page == 3:
            documents = [worst_organization_document(n) for n in range(page_size)]
            for document in documents:
                document["attributes"]["email"] = UNIFORM_WORST_MESSAGE
            return {"data": documents, "meta": pagination(next_page=4)}
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
    if path == f"/api/v2/organizations/{MEGA_ORGANIZATION}/workspaces":
        return {
            "data": [mega_workspace_document(n) for n in range(page_size)],
            "meta": pagination(next_page=2),
        }
    if path == f"/api/v2/workspaces/{WORST_WORKSPACE_ID}/runs":
        return {
            "data": [worst_run_document(n, m) for n, m in enumerate(WORST_MESSAGES[:page_size])],
            "meta": pagination(next_page=2),
        }
    if path == f"/api/v2/workspaces/{UNIFORM_WORST_WORKSPACE_ID}/runs":
        return {
            "data": [worst_run_document(n, UNIFORM_WORST_MESSAGE, UNIFORM_WORST_WORKSPACE_ID) for n in range(page_size)],
            "meta": pagination(next_page=2),
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
            body = LOG_BLOBS[path]()
            if isinstance(body, str):
                body = body.encode()
            self.write_bytes(200, "text/plain", body)
            return
        if path == "/blob/plan-json-output":
            self.write_json(200, plan_json_output())
            return
        if path == "/blob/worst-plan-json-output":
            self.write_json(200, worst_plan_json_output())
            return
        if path == "/blob/malformed-plan-json-output":
            self.write_json(200, malformed_plan_json_output())
            return
        if path == "/blob/future-format-plan-json-output":
            self.write_json(200, future_format_plan_json_output())
            return
        if not self.authenticated():
            return
        for run_id, blob in (
            (RUN_ID, "/blob/plan-json-output"),
            (WORST_PLAN_RUN_ID, "/blob/worst-plan-json-output"),
            (MALFORMED_PLAN_RUN_ID, "/blob/malformed-plan-json-output"),
            (FUTURE_FORMAT_PLAN_RUN_ID, "/blob/future-format-plan-json-output"),
        ):
            if path == f"/api/v2/runs/{run_id}/plan/json-output":
                self.send_response(307)
                self.send_header("Location", blob)
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
        payload = get_response(path, parse_qs(urlparse(self.path).query))
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
