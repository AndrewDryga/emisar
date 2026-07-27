import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ACCESS_TOKEN = "packtest-canary-gcp-monitoring-access-token-281b"
SAMPLE_TIME = "2026-07-27T22:00:00Z"


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


def response(raw_path):
    request = urlparse(raw_path)
    query = parse_qs(request.query, keep_blank_values=True)
    if request.path == "/health":
        return {"ok": True}
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
        return {
            "alertPolicies": [{
                "name": "projects/example-prod/alertPolicies/harness-policy",
                "displayName": "Harness CPU alert",
                "enabled": True,
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
            }]
        }
    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            authorization = self.headers.get("Authorization")
            if authorization != f"Bearer {ACCESS_TOKEN}":
                self.write_json(
                    401,
                    {"error": {"code": 401, "message": "invalid token"}},
                )
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
