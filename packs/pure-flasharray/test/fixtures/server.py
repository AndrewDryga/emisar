import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_TOKEN = "packtest-canary-pure-api-token-52ad"
SESSION_TOKEN = "packtest-pure-session"


def collection(items, *, cursor=None):
    return {
        "items": items,
        "more_items_remaining": cursor is not None,
        "total_item_count": len(items),
        "continuation_token": cursor,
        "errors": [],
    }


def response(path, query):
    if path == "/api/2.42/protection-groups":
        if query != {"limit": ["2"], "continuation_token": ["cursor-in"]}:
            return None
        return collection(
            [{
                "name": "harness-pgroup",
                "targets": [{"name": "harness-target"}],
                "replicate_enabled": True,
            }],
            cursor="cursor-out",
        )
    if path == "/api/2.42/container-default-protections":
        if query != {"limit": ["3"], "names": [""]}:
            return None
        return collection([{
            "container": {"name": "harness-array", "resource_type": "arrays"},
            "protection_groups": [{"name": "harness-default"}],
        }])
    if path == "/api/2.42/protection-group-snapshots":
        if query != {"limit": ["4"]}:
            return None
        return collection([{
            "name": "harness-pgroup.123",
            "source": {"name": "harness-pgroup"},
            "created": 1785196800000,
            "destroyed": False,
        }])
    if path == "/api/2.42/arrays/performance":
        # A window renders both bounds plus the resolution the action asked for.
        if sorted(query) != ["end_time", "limit", "resolution", "start_time"]:
            return None
        if query["resolution"] != ["1000"] or query["limit"] != ["1000"]:
            return None
        span = int(query["end_time"][0]) - int(query["start_time"][0])
        return collection([{
            "name": "harness-array",
            "window_ms": span,
            "usec_per_read_op": 412,
            "reads_per_sec": 9100,
        }])
    if path == "/api/2.42/volumes/performance":
        # A full page, reported the way the array reports it: nothing remains and
        # no continuation token, however much was left behind.
        if query != {"limit": ["3"]}:
            return None
        return collection([
            {"name": "harness-volume", "usec_per_read_op": 990},
            {"name": "harness-volume-warm", "usec_per_read_op": 310},
            {"name": "harness-volume-cool", "usec_per_read_op": 120},
        ])
    if path == "/api/2.42/hosts/performance":
        # Named host over a window: auto resolution for 24h is two hours.
        if sorted(query) != ["end_time", "limit", "names", "resolution", "start_time"]:
            return None
        if query["names"] != ["harness-host"] or query["resolution"] != ["7200000"]:
            return None
        return collection([{
            "name": "harness-host",
            "writes_per_sec": 4200,
        }])
    if path == "/api/2.42/network-interfaces/performance":
        if query != {"limit": ["5"], "names": ["ct0.eth4"]}:
            return None
        return collection([{
            "name": "ct0.eth4",
            "received_bytes_per_sec": 118000000,
        }])
    member_names = {
        "/api/2.42/protection-groups/volumes": "harness-volume",
        "/api/2.42/protection-groups/hosts": "harness-host",
        "/api/2.42/protection-groups/host-groups": "harness-host-group",
    }
    if path in member_names:
        if query != {"limit": ["5"]}:
            return None
        return collection([{
            "group": {"name": "harness-pgroup"},
            "member": {"name": member_names[path]},
        }])
    return None


class Handler(BaseHTTPRequestHandler):
    def write_json(self, status, payload, headers=None):
        body = json.dumps(payload).encode()
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/api/2.42/login":
            self.write_json(404, {"errors": [{"message": "not found"}]})
            return
        if self.headers.get("api-token") != API_TOKEN:
            self.write_json(401, {"errors": [{"message": "invalid token"}]})
            return
        self.write_json(200, {}, {"x-auth-token": SESSION_TOKEN})

    def do_GET(self):
        request = urlparse(self.path)
        if request.path == "/health":
            self.write_json(200, {"ok": True})
            return
        if request.path == "/api/api_version":
            self.write_json(200, {"versions": ["2.42"]})
            return
        if self.headers.get("x-auth-token") != SESSION_TOKEN:
            self.write_json(401, {"errors": [{"message": "invalid session"}]})
            return
        payload = response(
            request.path,
            parse_qs(request.query, keep_blank_values=True),
        )
        if payload is None:
            self.write_json(400, {"errors": [{"message": "unexpected request"}]})
            return
        self.write_json(200, payload)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
