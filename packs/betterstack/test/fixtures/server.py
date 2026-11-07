"""Deterministic HTTPS REST contract model, not a Better Stack backend.

All credentials, private fields and the fixture key are PUBLIC TEST DATA.
"""
import copy
import json
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

ACCESS = "packtest-canary-betterstack-access-e391"
PRIVATE = "packtest-canary-betterstack-hidden-content-7ba2"
ERROR = "packtest-canary-betterstack-error-8ac4"
NOW = "2026-11-07T12:34:56.123Z"
ORIGIN = "https://incidents.betterstack.com"


def resource(kind, identifier):
    common = {"created_at": NOW, "updated_at": NOW}
    if kind == "monitor":
        attrs = {**common, "monitor_type": "status", "status": "up", "paused": False,
                 "paused_at": None, "last_checked_at": NOW, "verify_ssl": True,
                 "check_frequency": 60, "effective_check_frequency": 60,
                 "request_timeout": 15, "confirmation_period": 120, "recovery_period": 180,
                 "http_method": "get", "call": False, "sms": False, "email": True,
                 "push": True, "critical_alert": False, "regions": ["us", "eu", "as", "au"],
                 "url": "https://user:" + PRIVATE + "@example.test/?private=" + PRIVATE,
                 "pronounceable_name": PRIVATE, "auth_username": PRIVATE, "auth_password": PRIVATE,
                 "request_headers": [{"name": "Authorization", "value": PRIVATE}],
                 "request_body": PRIVATE, "required_keyword": PRIVATE, "playwright_script": PRIVATE,
                 "proxy_host": PRIVATE, "environment_variables": {"password": PRIVATE}}
    elif kind == "heartbeat":
        attrs = {**common, "status": "up", "period": 10800, "grace": 300, "paused": False,
                 "paused_at": None, "call": False, "sms": False, "email": True, "push": True,
                 "critical_alert": False, "url": ORIGIN + "/api/v1/heartbeat/" + PRIVATE, "name": PRIVATE}
    elif kind == "incident":
        attrs = {"status": "Started", "started_at": NOW, "acknowledged_at": None,
                 "resolved_at": None, "acknowledged_by": PRIVATE, "resolved_by": PRIVATE,
                 "name": PRIVATE, "url": PRIVATE, "cause": PRIVATE, "response_content": PRIVATE,
                 "response_options": PRIVATE, "response_url": PRIVATE, "screenshot_url": PRIVATE,
                 "origin_url": PRIVATE, "metadata": {"payload": PRIVATE}}
    else:
        attrs = {**common, "aggregate_state": "operational", "published": True,
                 "password_enabled": True, "require_sso": False, "hide_from_search_engines": True,
                 "company_name": PRIVATE, "company_url": PRIVATE, "contact_url": PRIVATE,
                 "custom_javascript": PRIVATE, "custom_css": PRIVATE, "announcement": PRIVATE,
                 "ip_allowlist": [PRIVATE], "navigation_links": [PRIVATE], "subscribers": [PRIVATE]}
    result = {"id": identifier, "type": kind, "attributes": attrs}
    if kind == "incident":
        result["relationships"] = {"monitor": {"data": {"id": "101", "type": "monitor"}},
                                   "heartbeat": {"data": None}}
    return result


def initial():
    return {"monitors": {"101": resource("monitor", "101")},
            "heartbeats": {"201": resource("heartbeat", "201")},
            "incidents": {"301": resource("incident", "301")},
            "status-pages": {"401": resource("status_page", "401")}}


STATE = initial()
REQUESTS = []
SCENARIO = "normal"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send(self, status, data=None, raw=None, chunked=False):
        body = raw if raw is not None else (json.dumps(data).encode() if data is not None else b"")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Transfer-Encoding" if chunked else "Content-Length",
                         "chunked" if chunked else str(len(body)))
        self.end_headers()
        try:
            if chunked:
                for start in range(0, len(body), 8192):
                    chunk = body[start:start + 8192]
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def do_GET(self): self.handle_request("GET")
    def do_POST(self): self.handle_request("POST")
    def do_PATCH(self): self.handle_request("PATCH")
    def do_DELETE(self): self.handle_request("DELETE")

    def handle_request(self, method):
        global STATE, SCENARIO
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if parsed.path == "/health": return self.send(200, {})
        if parsed.path == "/__fixture/control" and method == "POST":
            value = json.loads(body)
            STATE = initial(); REQUESTS.clear(); SCENARIO = value.get("scenario", "normal")
            return self.send(200, {})
        if parsed.path == "/__fixture/state":
            return self.send(200, {"state": STATE, "requests": REQUESTS, "scenario": SCENARIO})
        if self.headers.get("Host") != "incidents.betterstack.com":
            return self.send(400, {"errors": ERROR})
        if self.headers.get("Authorization") != "Bearer " + ACCESS:
            return self.send(401, {"errors": ERROR, "private": PRIVATE})
        if SCENARIO.startswith("http-"):
            return self.send(int(SCENARIO[5:]), {"errors": ERROR, "private": PRIVATE})
        if SCENARIO == "slow":
            time.sleep(25)
        if SCENARIO == "redirect":
            self.send_response(302); self.send_header("Location", "https://outside.test/" + PRIVATE)
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if SCENARIO in ("oversize", "chunked-oversize"):
            return self.send(200, raw=b" " * 4194305, chunked=SCENARIO.startswith("chunked"))
        if SCENARIO == "invalid-json": return self.send(200, raw=b'{"data":' + ERROR.encode())
        if SCENARIO == "duplicate-json": return self.send(200, raw=b'{"data":{},"data":{}}')
        if SCENARIO == "nonfinite-json": return self.send(200, raw=b'{"data":1e400}')
        if SCENARIO == "empty-200": return self.send(200, raw=b'')
        pieces = parsed.path.strip("/").split("/")
        if len(pieces) < 3 or pieces[:2] not in (["api", "v2"], ["api", "v3"]):
            return self.send(404, {"errors": ERROR})
        family = pieces[2]
        expected = "v3" if family == "incidents" else "v2"
        if family not in STATE or pieces[1] != expected: return self.send(404, {"errors": ERROR})
        args = json.loads(body) if body else None
        REQUESTS.append({"method": method, "path": parsed.path, "query": query, "body": args})
        if len(pieces) == 3 and method == "GET":
            page, size = int(query.get("page", ["1"])[0]), int(query.get("per_page", ["6"])[0])
            kind = {"monitors": "monitor", "heartbeats": "heartbeat", "incidents": "incident", "status-pages": "status_page"}[family]
            rows = list(STATE[family].values())
            if SCENARIO == "max-page": rows = [resource(kind, "1234567890123456789" + str(i)) for i in range(6)]
            if SCENARIO == "max-page":
                def escaped_hidden(value):
                    if type(value) is str and PRIVATE in value:
                        return ('"\\\u2028\u2029' * 2048) + PRIVATE
                    if type(value) is list: return [escaped_hidden(x) for x in value]
                    if type(value) is dict: return {k: escaped_hidden(v) for k, v in value.items()}
                    return value
                for row in rows:
                    for key, value in row["attributes"].items():
                        if key.endswith("_at"):
                            row["attributes"][key] = "9999-12-31T23:59:59.123456789+23:59"
                        elif type(value) is int:
                            row["attributes"][key] = 9007199254740991
                    row["attributes"] = escaped_hidden(row["attributes"])
            if SCENARIO == "empty": rows = []
            next_url = None
            if page == 1 and SCENARIO != "empty":
                q = {k: v[0] for k, v in query.items()}; q["page"] = "2"
                next_url = ORIGIN + parsed.path + "?" + urlencode(q)
            if SCENARIO == "spoof-next": next_url = "https://outside.test" + parsed.path + "?page=2"
            if SCENARIO == "malformed-next":
                q = {k: v[0] for k, v in query.items()}; q["page"] = "no"
                next_url = ORIGIN + parsed.path + "?" + urlencode(q)
            if SCENARIO == "next-selector-change": next_url = ORIGIN + parsed.path + "?page=2&per_page=5"
            if SCENARIO == "next-no-progress": next_url = ORIGIN + parsed.path + "?" + urlencode({k: v[0] for k, v in query.items()})
            if SCENARIO == "next-duplicate": next_url = ORIGIN + parsed.path + "?page=2&page=3&per_page=6"
            if SCENARIO == "wrong-list": rows = None
            if SCENARIO == "wrong-type": rows[0]["type"] = "incorrect"
            if SCENARIO == "missing-pagination": return self.send(200, {"data": rows})
            return self.send(200, {"data": rows[:size] if type(rows) is list else rows, "pagination": {"next": next_url}, "included": [PRIVATE]})
        if len(pieces) == 3 and method == "POST" and family == "monitors":
            assert set(args) <= {"url", "monitor_type", "http_method", "verify_ssl", "check_frequency", "request_timeout", "confirmation_period", "recovery_period", "team_name"}
            assert args["monitor_type"] == "status" and args["verify_ssl"] is True
            assert args["http_method"] in ("GET", "HEAD")
            value = resource("monitor", "102"); value["attributes"].update(args)
            value["attributes"]["http_method"] = args["http_method"].lower()
            STATE[family]["102"] = value
            return self.send(201, {"data": value})
        identifier = pieces[3] if len(pieces) > 3 else ""
        value = STATE[family].get(identifier)
        if value is None: return self.send(404, {"errors": ERROR})
        if method == "DELETE" and family == "monitors":
            del STATE[family][identifier]; return self.send(204)
        if method == "PATCH" and family in ("monitors", "heartbeats"):
            allowed = {"check_frequency", "request_timeout", "confirmation_period", "recovery_period", "paused"} if family == "monitors" else {"period", "grace", "paused"}
            assert args and set(args) <= allowed
            if SCENARIO != "false-receipt": value["attributes"].update(args)
            if "paused" in args and SCENARIO != "false-receipt":
                value["attributes"].update(paused_at=NOW if args["paused"] else None,
                                           status="paused" if args["paused"] else "up")
        if method == "POST" and family == "incidents" and len(pieces) == 5:
            verb = pieces[4]
            field = "acknowledged" if verb == "acknowledge" else "resolved" if verb == "resolve" else None
            if field is None: return self.send(404, {})
            assert args == {field + "_by": "Emisar"}
            if value["attributes"][field + "_at"] is not None: return self.send(409, {"errors": ERROR})
            if SCENARIO != "false-receipt":
                value["attributes"][field + "_at"] = NOW
                value["attributes"]["status"] = "Acknowledged" if field == "acknowledged" else "Resolved"
        if len(pieces) == 5 and pieces[4] == "sla":
            value = {"id": identifier, "type": "monitor_sla", "attributes": {"availability": 99.98, "total_downtime": 600, "number_of_incidents": 3, "longest_incident": 300, "average_incident": 200}}
            if SCENARIO == "missing-metric": value["attributes"].pop("availability")
            if SCENARIO == "bad-metric": value["attributes"]["availability"] = 100.01
        if len(pieces) == 5 and pieces[4] == "response-times":
            times = [{"at": f"2026-11-07T12:34:{n + 50:02d}.123Z", "response_time": n / 10, "private": PRIVATE} for n in (1, 2, 3)]
            if SCENARIO == "large-metrics": times *= 2800
            value = {"id": identifier, "type": "monitor_response_times", "attributes": {"regions": [{"region": r, "response_times": times} for r in ("us", "eu", "as", "au")]}}
            if SCENARIO == "empty-metrics":
                for row in value["attributes"]["regions"]: row["response_times"] = []
            if SCENARIO == "missing-metric": value["attributes"]["regions"][0]["response_times"][0].pop("response_time")
            if SCENARIO == "bad-metric": value["attributes"]["regions"][0]["response_times"][0]["response_time"] = -1
            if SCENARIO == "duplicate-region": value["attributes"]["regions"][1]["region"] = "us"
        value = copy.deepcopy(value)
        if SCENARIO == "wrong-type": value["type"] = "incorrect"
        if SCENARIO == "wrong-id": value["id"] = "999"
        if SCENARIO == "server-monitor": value["attributes"]["monitor_type"] = "ping"
        if SCENARIO == "bad-field": value["attributes"]["paused"] = PRIVATE
        if SCENARIO == "bad-timestamp": value["attributes"]["created_at"] = PRIVATE
        if SCENARIO == "optional-absent":
            for k in ("created_at", "updated_at", "paused_at", "last_checked_at"): value["attributes"].pop(k, None)
        return self.send(200, {"data": value, "included": [PRIVATE]})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/fixture/server.crt", "/fixture/server-key.fixture")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
