import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ACCESS_TOKEN = "packtest-canary-gcp-monitoring-access-token-281b"
SAMPLE_TIME = "2026-07-27T22:00:00Z"
POLICY_ID = "8675309001234"

MUTATIONS = []
REQUESTS = []
POLICY_ENABLED = {"value": True}


def point(value):
    return {
        "interval": {"endTime": SAMPLE_TIME},
        "value": {"doubleValue": value},
    }


def metric_series(metric_type, value, resource_type):
    return {
        "metric": {"type": metric_type},
        "resource": {
            "type": resource_type,
            "labels": {
                "instance_id": "1001",
                "instance_name": "harness-vm",
                "project_id": "example-prod",
            },
        },
        "metricKind": "GAUGE",
        "valueType": "DOUBLE",
        "points": [point(value)],
    }


def alert_policy():
    return {
        "name": f"projects/example-prod/alertPolicies/{POLICY_ID}",
        "displayName": "Harness CPU alert",
        "enabled": POLICY_ENABLED["value"],
        "combiner": "OR",
        "notificationChannels": [
            "projects/example-prod/notificationChannels/harness-channel"
        ],
        "conditions": [{
            "displayName": "CPU high",
            "conditionThreshold": {
                "filter": (
                    'metric.type="compute.googleapis.com/instance/'
                    'cpu/utilization"'
                ),
                "comparison": "COMPARISON_GT",
                "thresholdValue": 0.9,
            },
        }],
    }


def response(raw_path):
    request = urlparse(raw_path)
    query = parse_qs(request.query, keep_blank_values=True)
    if request.path == "/health":
        return {"ok": True}
    if request.path == "/probe/state":
        return {"mutations": MUTATIONS, "requests": REQUESTS}
    if request.path == "/v2/projects/example-prod/logs":
        if query.get("pageToken", [""])[0] == "worst-case":
            return {
                "logNames": ["\u2028" * 400 for _ in range(8)],
                "nextPageToken": "C" * 1024,
            }
        return {
            "logNames": [
                "projects/example-prod/logs/harness-api",
                "projects/example-prod/logs/harness-worker",
            ],
            "nextPageToken": "log-names-next",
        }
    if request.path.endswith("/metricDescriptors"):
        return {
            "metricDescriptors": [{
                "type": "compute.googleapis.com/instance/cpu/utilization",
                "metricKind": "GAUGE",
                "valueType": "DOUBLE",
                "unit": "10^2.%",
                "displayName": "CPU utilization",
            }]
        }
    if request.path.endswith("/timeSeries"):
        filter_value = query.get("filter", [""])[0]
        if "network/attachment/capacity" in filter_value:
            return {
                "timeSeries": [metric_series(
                    "interconnect.googleapis.com/network/attachment/capacity",
                    1000000,
                    "interconnect_attachment",
                )]
            }
        if "received_bytes_count" in filter_value:
            return {
                "timeSeries": [metric_series(
                    "interconnect.googleapis.com/network/attachment/"
                    "received_bytes_count",
                    250000,
                    "interconnect_attachment",
                )]
            }
        if "sent_bytes_count" in filter_value:
            return {
                "timeSeries": [metric_series(
                    "interconnect.googleapis.com/network/attachment/"
                    "sent_bytes_count",
                    500000,
                    "interconnect_attachment",
                )]
            }
        if (
            "compute.googleapis.com/instance/cpu/utilization"
            in filter_value
        ):
            return {
                "timeSeries": [metric_series(
                    "compute.googleapis.com/instance/cpu/utilization",
                    0.42,
                    "gce_instance",
                )]
            }
    if request.path.endswith("/alertPolicies"):
        return {"alertPolicies": [alert_policy()]}
    return None


def log_entries(request_body):
    filter_value = request_body.get("filter", "")
    if "worst_case" in filter_value:
        flood = "\u2028" * 400
        return {
            "entries": [{
                "timestamp": flood,
                "severity": flood,
                "resource": {"type": flood},
                "logName": flood,
                "textPayload": flood,
            } for _ in range(5)],
            "nextPageToken": "N" * 1200,
        }
    return {
        "entries": [
            {
                "timestamp": "2026-08-15T06:30:00Z",
                "severity": "ERROR",
                "resource": {"type": "gce_instance"},
                "logName": "projects/example-prod/logs/harness-api",
                "textPayload": (
                    "harness log event Authorization: Bearer "
                    "packtest-canary-gcp-log-bearer-7498"
                ),
            },
            {
                "timestamp": "2026-08-15T06:29:00Z",
                "severity": "WARNING",
                "resource": {"type": "cloud_run_revision"},
                "logName": "projects/example-prod/logs/harness-worker",
                "jsonPayload": {
                    "message": f"worker retry {ACCESS_TOKEN}",
                    "event": "worker retry",
                    "attempt": 2,
                    "internalCredential": ACCESS_TOKEN,
                },
            },
        ],
        "nextPageToken": "log-entries-next",
    }


def patch_response(raw_path, body):
    request = urlparse(raw_path)
    query = parse_qs(request.query, keep_blank_values=True)
    if request.path.endswith(f"/alertPolicies/{POLICY_ID}"):
        if query.get("updateMask", [None])[0] != "enabled":
            return None
        enabled = json.loads(body).get("enabled")
        if not isinstance(enabled, bool):
            return None
        POLICY_ENABLED["value"] = enabled
        MUTATIONS.append(f"patch:{POLICY_ID}:enabled={str(enabled).lower()}")
        return alert_policy()
    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.authorized():
            return
        payload = response(self.path)
        if payload is None:
            self.write_json(
                404,
                {"error": {
                    "code": 404,
                    "message": f"unhandled path {self.path}",
                }},
            )
            return
        self.write_json(200, payload)

    def do_PATCH(self):
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        payload = patch_response(self.path, body)
        if payload is None:
            self.write_json(
                404,
                {"error": {
                    "code": 404,
                    "message": f"unhandled patch {self.path}",
                }},
            )
            return
        self.write_json(200, payload)

    def do_POST(self):
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else "{}"
        if urlparse(self.path).path != "/v2/entries:list":
            self.write_json(
                404,
                {"error": {
                    "code": 404,
                    "message": f"unhandled post {self.path}",
                }},
            )
            return
        try:
            request_body = json.loads(body)
        except json.JSONDecodeError:
            self.write_json(400, {"error": {"message": "invalid json"}})
            return
        REQUESTS.append(request_body)
        if "provider_failure" in request_body.get("filter", ""):
            self.write_json(
                503,
                {"error": {"code": 503, "message": "fixture unavailable"}},
            )
            return
        self.write_json(200, log_entries(request_body))

    def authorized(self):
        if urlparse(self.path).path in ("/health", "/probe/state"):
            return True
        authorization = self.headers.get("Authorization")
        if authorization != f"Bearer {ACCESS_TOKEN}":
            self.write_json(
                401,
                {"error": {"code": 401, "message": "invalid token"}},
            )
            return False
        return True

    def write_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
