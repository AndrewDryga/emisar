"""Deterministic Dataproc v1 contract model, not a Google deployment."""
import copy
import json
import re
import ssl
import threading
import driver_fixture
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ACCESS = "packtest-canary-dataproc-access-27bb"
PRIVATE = "packtest-canary-dataproc-private-payload-946c"
EXTRA = "packtest-canary-dataproc-error-envelope-8fe1"
UUID = "9e52399f-eaa6-4fd0-a41b-d847812b356b"
OP = "11111111-1111-4111-8111-111111111111"
BASE = "projects/example-prod/regions/us-central1"
REQUESTS = []


def cluster(name="lol-20261107", state="RUNNING"):
    return {
        "clusterName": name, "clusterUuid": UUID, "projectId": "example-prod",
        "status": {"state": state, "stateStartTime": "2026-11-07T10:00:00Z", "detail": PRIVATE},
        "labels": {"password": PRIVATE},
        "config": {
            "masterConfig": {"numInstances": 1, "machineTypeUri": "n2-standard-4"},
            "workerConfig": {"numInstances": 2, "machineTypeUri": "n2-standard-8"},
            "secondaryWorkerConfig": {"numInstances": 4, "preemptibility": "SPOT"},
            "softwareConfig": {"imageVersion": "2.2.64-debian12", "properties": {"spark:secret": PRIVATE}},
            "gceClusterConfig": {"zoneUri": "zones/us-central1-a", "serviceAccount": "analytics@example-prod.iam.gserviceaccount.com", "metadata": {"private": PRIVATE}},
            "autoscalingConfig": {"policyUri": BASE + "/autoscalingPolicies/analytics"},
            "lifecycleConfig": {"idleDeleteTtl": "1800s", "autoDeleteTime": "2026-11-08T10:00:00Z"},
        },
        "metrics": {"hdfsMetrics": {"CapacityTotal": "1099511627776", "CapacityUsed": "4096"}, "yarnMetrics": {"AppsRunning": "2", "AppsFailed": "1"}},
    }


def job(name="failed-job", state="ERROR"):
    return {
        "reference": {"projectId": "example-prod", "jobId": name},
        "placement": {"clusterName": "lol-20261107", "clusterUuid": UUID},
        "status": {"state": state, "substate": "UNSPECIFIED", "stateStartTime": "2026-11-07T10:05:00Z", "details": "Executor failed Authorization: Bearer packtest-canary-dataproc-error-bearer-8442"},
        "statusHistory": [{"state": "RUNNING", "stateStartTime": "2026-11-07T10:01:00Z"}],
        "yarnApplications": [{"name": "application_1770000_1", "state": "FAILED", "progress": 42, "trackingUrl": "https://internal/?secret=" + PRIVATE}],
        "pysparkJob": {"mainPythonFileUri": "gs://private/job.py", "args": [PRIVATE], "properties": {"password": PRIVATE}},
        "driverOutputResourceUri": "gs://private/" + PRIVATE,
    }


def operation(done=False):
    return {"name": BASE + "/operations/" + OP, "done": done,
            "metadata": {"clusterName": "lol-20261107", "clusterUuid": UUID, "operationType": "UPDATE", "description": PRIVATE,
                         "status": {"state": "DONE" if done else "RUNNING", "innerState": "RUNNING", "stateStartTime": "2026-11-07T10:00:00Z"}},
            "response": {"config": {"secret": PRIVATE}}}


def policy():
    return {"id": "analytics", "name": BASE + "/autoscalingPolicies/analytics", "labels": {"secret": PRIVATE},
            "workerConfig": {"minInstances": 2, "maxInstances": 20, "weight": 1},
            "secondaryWorkerConfig": {"minInstances": 0, "maxInstances": 100, "weight": 2},
            "basicAlgorithm": {"cooldownPeriod": "120s", "yarnConfig": {"scaleUpFactor": 0.5, "scaleDownFactor": 0.25, "scaleUpMinWorkerFraction": 0.1, "scaleDownMinWorkerFraction": 0.1, "gracefulDecommissionTimeout": "600s"}}}


CLUSTERS = {"lol-20261107": cluster(), "cold-cluster": cluster("cold-cluster", "STOPPED")}
JOBS = {"failed-job": job(), "active-job": job("active-job", "RUNNING")}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, code, message):
        status = {403: "PERMISSION_DENIED", 404: "NOT_FOUND", 412: "FAILED_PRECONDITION"}.get(code, "INVALID_ARGUMENT")
        self.send(code, {"error": {"code": code, "status": status, "message": message, "details": [{"private": EXTRA}]}, "private": EXTRA})

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def do_PATCH(self):
        self.handle_request("PATCH")

    def do_DELETE(self):
        self.handle_request("DELETE")

    def handle_request(self, method):
        u = urlparse(self.path)
        if u.path == "/health":
            self.send(200, {})
            return
        if u.path == "/probe/state":
            self.send(200, {"requests": REQUESTS, "clusters": CLUSTERS, "jobs": JOBS})
            return
        if self.headers.get("Authorization") != "Bearer " + ACCESS:
            self.error(403, "Dataproc permission denied")
            return
        # This modeled identity has the pack's fourteen Dataproc permissions,
        # not serviceusage.services.use for an explicit quota override.
        if self.headers.get("X-Goog-User-Project") is not None:
            self.error(403, "Explicit quota project permission denied")
            return
        if driver_fixture.handle(self, method, REQUESTS):
            return
        m = re.fullmatch(r"/v1/projects/([^/]+)/regions/([^/]+)/(clusters|jobs|operations|autoscalingPolicies)(?:/([^/]+))?", u.path)
        if not m:
            self.error(404, "Unknown Dataproc v1 resource")
            return
        project, region, family, target = m.groups()
        query = parse_qs(u.query)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        REQUESTS.append({"method": method, "project": project, "region": region, "family": family, "target": target, "query": query, "body": body, "quota_project": self.headers.get("X-Goog-User-Project")})
        if project == "denied-prod":
            self.error(403, "Dataproc permission denied")
            return
        if project == "oversize-prod":
            self.send(200, {"padding": "x" * 4194305})
            return
        if project == "chunked-prod":
            self.protocol_version = "HTTP/1.1"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(600):
                    chunk = b"x" * 8192
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            return
        if region != "us-central1":
            self.error(404, "Region has no fixture resources")
            return
        if method == "GET" and not target:
            key = {"clusters": "clusters", "jobs": "jobs", "operations": "operations", "autoscalingPolicies": "policies"}[family]
            if project == "malformed-prod":
                self.send(200, {key: PRIVATE})
                return
            rows = list(CLUSTERS.values()) if family == "clusters" else list(JOBS.values()) if family == "jobs" else [operation()] if family == "operations" else [policy()]
            if family == "jobs":
                name = query.get("clusterName", [""])[0]
                matcher = query.get("jobStateMatcher", ["ALL"])[0]
                rows = [r for r in rows if (not name or r["placement"]["clusterName"] == name) and (matcher == "ALL" or ((r["status"]["state"] == "RUNNING") == (matcher == "ACTIVE")))]
            if project == "empty-prod":
                rows = []
            cursor = query.get("pageToken", [""])[0]
            if cursor == "page-two":
                rows = rows[1:]
            if project == "worst-prod":
                rows = [copy.deepcopy(rows[0]) for _ in range(8)]
                def flood(x, key=""):
                    if isinstance(x, dict):
                        return {k: flood(v, k) for k, v in x.items()}
                    if isinstance(x, list):
                        return [flood(v, key) for v in x]
                    if key == "clusterName":
                        return "c" * 51
                    if key == "clusterUuid":
                        return UUID
                    if key == "jobId":
                        return "J" * 100
                    if key == "id":
                        return "P" * 50
                    if key == "name":
                        return BASE + "/operations/" + "O" * 40
                    return "\u2028" * 500 if isinstance(x, str) else x
                rows = [flood(r) for r in rows]
            size = int(query.get("pageSize", ["8"])[0])
            continuation = "C" * 1024 if project == "worst-prod" else "cursor?unsupported" if project == "badcursor-prod" else "page-two" if rows and not cursor else ""
            self.send(200, {key: rows[:size], "nextPageToken": continuation, **({"unreachable": ["kms-job"]} if family == "jobs" else {})})
            return
        if family == "clusters":
            name, _, action = (target or "").partition(":")
            if name not in CLUSTERS:
                self.error(404, "Cluster not found")
                return
            c = CLUSTERS[name]
            if method == "GET":
                result = copy.deepcopy(c)
                if project == "longuri-prod":
                    result["config"]["autoscalingConfig"]["policyUri"] = "https://dataproc.googleapis.com/v1/projects/" + "p" * 30 + "/regions/" + "r" * 63 + "/autoscalingPolicies/" + "A" * 50
                if project == "empty-prod":
                    result.pop("metrics", None)
                if project == "malformed-prod":
                    result["metrics"] = {"hdfsMetrics": {"bad": PRIVATE}}
                if project == "worst-prod":
                    result["metrics"] = {k: {str(n) + "\u2028" * 100: "9223372036854775807" for n in range(30)} for k in ["hdfsMetrics", "yarnMetrics"]}
                self.send(200, result)
                return
            if method == "POST" and action in ("start", "stop"):
                if body.get("clusterUuid") != UUID or set(body) != {"clusterUuid"}:
                    self.error(400, "Expected exact cluster UUID guard")
                    return
                c["status"]["state"] = "STARTING" if action == "start" else "STOPPING"
            elif method == "PATCH":
                mask = query.get("updateMask", [""])[0]
                field = {"config.worker_config.num_instances": "workerConfig", "config.secondary_worker_config.num_instances": "secondaryWorkerConfig"}.get(mask)
                if not field or set(body) != {"config"} or set(body["config"]) != {field} or set(body["config"][field]) != {"numInstances"} or "gracefulDecommissionTimeout" not in query:
                    self.error(400, "Expected one narrow worker update mask and body")
                    return
                c["config"][field]["numInstances"] = body["config"][field]["numInstances"]
            elif method == "DELETE":
                if query.get("clusterUuid") != [UUID]:
                    self.error(400, "Expected exact cluster UUID guard")
                    return
                del CLUSTERS[name]
            else:
                self.error(400, "Unsupported cluster mutation")
                return
            self.send(200, operation())
            return
        if family == "jobs":
            name, _, action = (target or "").partition(":")
            if method == "GET" and name.startswith("driver-"):
                if self.headers.get("Accept-Encoding") != "identity":
                    self.error(400, "Job metadata must request identity encoding")
                    return
                self.send(200, driver_fixture.driver_job(name, job))
                return
            if name not in JOBS:
                self.error(404, "Job not found")
                return
            if method == "GET":
                result = copy.deepcopy(JOBS[name])
                if project == "pending-prod":
                    result["placement"].pop("clusterUuid", None)
                    result["status"] = {"state": "PENDING"}
                    result.pop("yarnApplications", None)
                if project == "worst-prod":
                    result["status"]["details"] = "\u2028" * 1000
                    result["statusHistory"] = [{"state": "\u2028" * 100, "stateStartTime": "\u2028" * 100} for _ in range(10)]
                    result["yarnApplications"] = [{"name": "\u2028" * 1000, "state": "\u2028" * 100, "progress": 42} for _ in range(10)]
                self.send(200, result)
            elif method == "POST" and action == "cancel" and body == {}:
                JOBS[name]["status"]["state"] = "CANCEL_PENDING"
                self.send(200, JOBS[name])
            elif method == "DELETE" and JOBS[name]["status"]["state"] not in ("RUNNING", "PENDING"):
                del JOBS[name]
                self.send(200, {})
            else:
                self.error(412, "Active jobs must be cancelled before deletion")
            return
        if family == "operations" and method == "GET" and target == OP:
            result = operation(True)
            result["error"] = {"code": 9, "message": "Quota blocked Authorization: Bearer packtest-canary-dataproc-error-bearer-8442", "details": [{"private": PRIVATE}]}
            if project == "worst-prod":
                result["error"]["message"] = "\u2028" * 1000
            self.send(200, result)
            return
        if family == "autoscalingPolicies" and method == "GET" and target == "analytics":
            self.send(200, policy())
            return
        self.error(404, "Resource not found")


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
def serve(port):
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()

threading.Thread(target=serve, args=(443,), daemon=True).start()
serve(8443)
