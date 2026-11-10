import json
from pathlib import Path
import re
import ssl
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ACCESS_TOKEN = "packtest-canary-gcp-monitoring-access-token-281b"
VIEW_ACCESS_TOKEN = "packtest-canary-gcp-monitoring-view-access-9581"
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


def metric_series(metric_type, value, resource_type, labels=None):
    return {
        "metric": {"type": metric_type},
        "resource": {
            "type": resource_type,
            "labels": labels if labels is not None else {
                "instance_id": "1001",
                "instance_name": "harness-vm",
                "project_id": "example-prod",
            },
        },
        "metricKind": "GAUGE",
        "valueType": "DOUBLE",
        "points": [point(value)],
    }


class InvalidFilter(ValueError):
    pass


def interconnect_series(filter_value, query):
    # This fixture models the AND/equality selectors authored by these actions,
    # not Google's complete filter language. In particular, a valid unmatched
    # selector is empty data, while an unknown resource label is a descriptor error.
    comparisons = re.findall(
        r'(metric\.type|resource\.type|resource\.labels\.[a-z_]+)\s*=\s*"([^"\n]*)"',
        filter_value,
    )
    token_pattern = re.compile(
        r'\s*(AND\b|[()]|(?:metric\.type|resource\.type|resource\.labels\.[a-z_]+)\s*=\s*"[^"\n]*")'
    )
    position, depth, operand = 0, 0, True
    while position < len(filter_value):
        if not filter_value[position:].strip():
            break
        token = token_pattern.match(filter_value, position)
        if token is None:
            raise InvalidFilter('Malformed fixture filter')
        position = token.end()
        value = token.group(1)
        if value == '(' and operand:
            depth += 1
        elif value == ')' and not operand and depth > 0:
            depth -= 1
        elif value == 'AND' and not operand:
            operand = True
        elif value not in ('AND', '(', ')') and operand:
            operand = False
        else:
            raise InvalidFilter('Malformed fixture filter')
    if operand or depth:
        raise InvalidFilter('Malformed fixture filter')
    real_labels = {'project_id', 'attachment', 'interconnect', 'region', 'interconnect_project'}
    for key, value in comparisons:
        if key.startswith('resource.labels.') and key.removeprefix('resource.labels.') not in real_labels:
            raise InvalidFilter('The supplied filter does not specify a valid combination of metric and monitored resource descriptors.')
        if key == 'resource.type' and value != 'interconnect_attachment':
            raise InvalidFilter('The supplied filter does not specify a valid combination of metric and monitored resource descriptors.')
    metric = next(value for key, value in comparisons if key == 'metric.type')
    suffix = metric.removeprefix('interconnect.googleapis.com/network/attachment/')
    values = {'capacity': 1000000, 'received_bytes_count': 250000, 'sent_bytes_count': 500000}
    aligner = query.get('aggregation.perSeriesAligner', ['ALIGN_NONE'])[0]
    if aligner != ('ALIGN_MEAN' if suffix == 'capacity' else 'ALIGN_RATE'):
        raise InvalidFilter('Fixture expected capacity mean or byte rate alignment')
    labels = {
        'project_id': 'example-prod', 'attachment': 'harness-attachment',
        'interconnect': 'harness-interconnect', 'region': 'us-central1',
        'interconnect_project': 'example-prod',
    }
    candidates = [labels, {**labels, 'project_id': 'another-prod'},
                  {**labels, 'attachment': 'another-attachment'},
                  {**labels, 'region': 'us-east1'}]
    # Existing-resource special states prove null is not fabricated zero usage.
    candidates += [{**labels, 'attachment': name} for name in ('missing-capacity', 'zero-capacity')]
    result = []
    for candidate in candidates:
        if not all(candidate[key.removeprefix('resource.labels.')] == value
                   for key, value in comparisons if key.startswith('resource.labels.')):
            continue
        value = 0 if suffix == 'capacity' and candidate['attachment'] == 'zero-capacity' else values[suffix]
        series = metric_series(metric, value, 'interconnect_attachment', candidate)
        if suffix == 'capacity' and candidate['attachment'] == 'missing-capacity':
            series['points'] = []
        result.append(series)
    return {'timeSeries': result}


def time_series_request(query):
    request = {key: values[0] for key, values in query.items()}
    start = request.get("interval.startTime")
    end = request.get("interval.endTime")
    if start and end:
        layout = "%Y-%m-%dT%H:%M:%SZ"
        delta = datetime.strptime(end, layout) - datetime.strptime(start, layout)
        request["interval_minutes"] = int(delta.total_seconds() // 60)
    return request


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
        REQUESTS.append(time_series_request(query))
        filter_value = query.get("filter", [""])[0]
        if any('interconnect.googleapis.com/network/attachment/' + suffix in filter_value
               for suffix in ('capacity', 'received_bytes_count', 'sent_bytes_count')):
            return interconnect_series(filter_value, query)
        if (
            "compute.googleapis.com/instance/cpu/utilization"
            in filter_value
        ):
            cursor = query.get("pageToken", [""])[0]
            provider_cursor = "M" * 2048 if "max_cursor" in filter_value else "metric.next+/_=-~"
            if cursor:
                current = {key: value for key, value in REQUESTS[-1].items() if key != "pageToken"}
                previous = {key: value for key, value in REQUESTS[-2].items() if key != "pageToken"} if len(REQUESTS) > 1 else None
                if cursor != provider_cursor or current != previous:
                    raise InvalidFilter("For pagination, all request parameters except pageToken must match the original request.")
                continued = metric_series(
                    "compute.googleapis.com/instance/cpu/utilization",
                    0.84,
                    "gce_instance",
                )
                continued["resource"]["labels"]["instance_id"] = "1002"
                return {"timeSeries": [continued]}
            payload = {
                "timeSeries": [metric_series(
                    "compute.googleapis.com/instance/cpu/utilization",
                    0.42,
                    "gce_instance",
                )]
            }
            if query.get("pageSize") == ["1"]:
                payload["nextPageToken"] = provider_cursor
            return payload
    if request.path.endswith("/alertPolicies"):
        return {"alertPolicies": [alert_policy()]}
    return None


def log_entries(request_body, access_token):
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
                "jsonPayload": {"job": flood, "error": flood},
            } for _ in range(5)],
            "nextPageToken": "N" * (1024 if "valid_cursor" in filter_value else 1200),
        }
    return {
        "entries": [
            {
                "timestamp": "2026-08-15T06:30:00Z",
                "severity": "ERROR",
                "resource": {"type": "gce_instance"},
                "logName": "projects/example-prod/logs/harness-api",
                "jsonPayload": {
                    "message": (
                        "harness log event Authorization: Bearer "
                        "packtest-canary-gcp-log-bearer-7498"
                    ),
                    "job": "Emisar.Runs.Jobs.FleetObservability",
                    "error": "DBConnection.ConnectionError",
                },
            },
            {
                "timestamp": "2026-08-15T06:29:00Z",
                "severity": "WARNING",
                "resource": {"type": "cloud_run_revision"},
                "logName": "projects/example-prod/logs/harness-worker",
                "jsonPayload": {
                    "message": f"worker retry {access_token}",
                    "job": "Emisar.Runbooks.Jobs.AdvanceExecutions",
                    "error": "DBConnection.ConnectionError",
                    "event": "worker retry",
                    "attempt": 2,
                    "internalCredential": access_token,
                },
            },
        ],
        "nextPageToken": ("C" * 1024 if "max_cursor" in filter_value else
                          "log.entries+/_=-~" if "cursor_punctuation" in filter_value else "log-entries-next"),
    }


def log_entry_detail(request_body, access_token):
    # The nested probe fields were harvested from a production diagnostic that
    # otherwise required six manual JSON requests. Identity is pseudonymized.
    value = request_body.get("filter", "")
    parts = re.findall(r'(timestamp|logName|insertId) = ("(?:\\.|[^"\\])*")', value)
    selectors = {name: json.loads(raw) for name, raw in parts}
    if not selectors.get("timestamp") or not selectors.get("logName") or request_body.get("pageSize") != 2:
        raise InvalidFilter("Detail must use exact log/time selectors and a two-entry ambiguity bound")
    if selectors["timestamp"] != "2026-11-08T01:17:13.871966957Z":
        return {"entries": []}
    entry = json.loads(Path("/fixture/healthcheck.json").read_text())
    entry["logName"] = selectors["logName"]
    log_id = selectors["logName"].split("/logs/", 1)[1]
    provider_cursor = request_body.get("pageToken", "")
    if log_id == "healthcheck-large-max-cursors":
        if not provider_cursor:
            return {"entries": [], "nextPageToken": "P" * 1024}
        if provider_cursor == "Q" * 1024:
            return {"entries": []}
    if log_id in ("healthcheck-empty-first", "healthcheck-one-first-empty-last", "healthcheck-two-pages", "healthcheck-large-empty-last"):
        if log_id == "healthcheck-empty-first" and not provider_cursor:
            return {"entries": [], "nextPageToken": "detail-empty-first-next"}
        if log_id in ("healthcheck-one-first-empty-last", "healthcheck-large-empty-last") and provider_cursor:
            return {"entries": []}
        if log_id == "healthcheck-two-pages" and provider_cursor:
            entry["insertId"] = "harness-probe-002"
    if log_id == "healthcheck-incomplete":
        return {"entries": [], "nextPageToken": "query-in-progress"}
    if log_id == "healthcheck-malformed":
        return {"entries": {"unexpected": True}}
    if log_id == "healthcheck-identity":
        entry["insertId"] = ('"' + chr(92) + chr(0x2028)) * 600
    if log_id == "healthcheck-missing":
        return {"entries": []}
    if log_id in ("healthcheck-large", "healthcheck-changing", "healthcheck-large-empty-last", "healthcheck-large-max-cursors"):
        entry["jsonPayload"]["oversized"] = ('quoted "' + chr(92) + chr(0x2028)) * 1000
        if log_id == "healthcheck-changing" and len(REQUESTS) > 1:
            entry["jsonPayload"]["changed"] = True
    if log_id == "healthcheck-sensitive":
        entry["jsonPayload"]["apiKey"] = "packtest-canary-detail-apikey-9345"
        entry["jsonPayload"]["password"] = "packtest-canary-detail-password-3184"
        entry["jsonPayload"]["access_token"] = "packtest-canary-detail-token-9317"
        entry["jsonPayload"]["message"] = f"before Authorization: Bearer packtest-canary-gcp-log-bearer-7498 after {access_token}"
    entries = [entry]
    if log_id == "healthcheck-ambiguous":
        other = json.loads(json.dumps(entry));other["insertId"] = "harness-probe-002";entries.append(other)
    if "insertId" in selectors:
        entries = [entry for entry in entries if entry["insertId"] == selectors["insertId"]]
    if log_id == "healthcheck-wrong-time" and entries:
        entries[0]["timestamp"] = "2026-11-08T01:17:13.871966958Z"
    if log_id == "healthcheck-wrong-id" and entries:
        entries[0]["insertId"] = "not-the-requested-id"
    result = {"entries": entries}
    if log_id == "healthcheck-large-max-cursors" and provider_cursor == "P" * 1024:
        result["nextPageToken"] = "Q" * 1024
    if log_id in ("healthcheck-one-first-empty-last", "healthcheck-large-empty-last", "healthcheck-two-pages") and not provider_cursor:
        result["nextPageToken"] = "detail-next-page"
    return result


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
        # Any read whose query carries the sentinel answers a structured 5xx,
        # so a case can drive a provider error through the capture sites in
        # monitoring_api.sh. The hyphen spelling is for interconnect, whose
        # attachment name may not contain an underscore.
        if any(s in urlparse(self.path).query
               for s in ("provider_failure", "provider-failure")):
            self.write_json(
                503,
                {"error": {"code": 503, "message": "fixture unavailable"}},
            )
            return
        try:
            payload = response(self.path)
        except InvalidFilter as error:
            self.write_json(400, {"error": {"code": 400, "status": "INVALID_ARGUMENT", "message": str(error)}})
            return
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
        if self.headers.get("Authorization") == f"Bearer {VIEW_ACCESS_TOKEN}" and request_body.get("resourceNames") != [
            "projects/example-prod/locations/global/buckets/_Default/views/emisar-vm-containers"
        ]:
            self.write_json(403, {"error": {"code": 403, "message": "Permission denied for this log scope"}})
            return
        if request_body.get("pageToken") and 'timestamp = "' not in request_body.get("filter", ""):
            current = {k: v for k, v in request_body.items() if k != "pageToken"}
            previous = {k: v for k, v in REQUESTS[-2].items() if k != "pageToken"} if len(REQUESTS) > 1 else None
            if current != previous:
                self.write_json(400, {"error": {"message": "continuation query changed"}})
                return
        if "provider_failure" in request_body.get("filter", ""):
            self.write_json(
                503,
                {"error": {"code": 503, "message": "fixture unavailable"}},
            )
            return
        try:
            if 'timestamp = "' in request_body.get("filter", ""):
                payload = log_entry_detail(request_body, self.headers["Authorization"].removeprefix("Bearer "))
            else:
                payload = log_entries(request_body, self.headers["Authorization"].removeprefix("Bearer "))
        except InvalidFilter as error:
            self.write_json(400, {"error": {"code": 400, "message": str(error)}})
            return
        if request_body.get("pageToken") and 'timestamp = "' not in request_body.get("filter", ""):
            payload["entries"][0]["jsonPayload"]["job"] = "continued-page"
            payload.pop("nextPageToken", None)
        self.write_json(200, payload)

    def authorized(self):
        if urlparse(self.path).path in ("/health", "/probe/state"):
            return True
        authorization = self.headers.get("Authorization")
        if authorization not in (f"Bearer {ACCESS_TOKEN}", f"Bearer {VIEW_ACCESS_TOKEN}"):
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
