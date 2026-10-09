"""HTTP faults supplement, never replace, the native Grafana behavior cases."""

import base64
import copy
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

CANARY = "packtest-canary-grafana-unrequested-783c"
MODE = "ok"
OBSERVED = []


def rules():
    rule = {
        "uid": "fixture-alert", "name": "Fixture alert", "type": "alerting",
        "isPaused": False, "state": "firing", "health": "error",
        "lastEvaluation": "2026-10-09T00:00:00Z",
        "labels": {"team": "platform", "summary": "Full label λ", "password": CANARY},
        "totals": {"alerting": 2, "error": 1},
        "query": CANARY, "annotations": {"summary": CANARY},
        "alerts": [{"value": CANARY}], "lastError": CANARY,
        "notificationSettings": {"receiver": CANARY}, "unknown": CANARY,
    }
    group = {
        "name": "fixture-group", "file": "fixture-folder", "folderUid": "fixture-folder-uid",
        "interval": 60, "lastEvaluation": "2026-10-09T00:00:00Z",
        "totals": {"firing": 1, "error": 1}, "rules": [rule], "unknown": CANARY,
    }
    recording = {
        "uid": "fixture-recording", "name": "Fixture recording", "type": "recording",
        "isPaused": True, "health": "ok", "lastEvaluation": "2026-10-09T00:00:00Z",
        "query": CANARY,
    }
    second = copy.deepcopy(group)
    second.update(name="second-group", file="second-folder", folderUid="second-folder-uid",
                  rules=[recording], totals={})
    return {"status": "success", "data": {"groups": [group, second],
            "totals": {"firing": 1, "error": 1}, "unknown": CANARY}, "unknown": CANARY}


def version():
    return {
        "buildInfo": {"version": "13.2.3", "commit": "fixture-commit", "edition": "Open Source",
                      "env": "production", "unknown": CANARY},
        "licenseInfo": {"expiry": 0, "edition": "Open Source", "stateInfo": "",
                        "enabledFeatures": {"unknown": CANARY}},
        "panels": {"unknown": CANARY}, "apps": {"unknown": CANARY},
        "datasources": {"unknown": CANARY}, "postHogToken": CANARY,
        "publicDashboardAccessToken": CANARY, "unknown": CANARY,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, body, status=200, extra_length=0, location=None):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body) + extra_length))
        self.send_header("Content-Type", "application/json")
        if location:
            self.send_header("Location", location)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # A bounded action is expected to close an oversized response.
        if extra_length:
            self.close_connection = True

    def do_GET(self):
        global MODE
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/health":
            return self.reply({"ok": True})
        if url.path == "/configure":
            MODE = query["mode"][0]
            OBSERVED.clear()
            return self.reply({"ok": True})
        if url.path == "/probe/state":
            return self.reply({"requests": OBSERVED})
        if url.path == "/redirected":
            OBSERVED.append({"redirected": True})
            return self.reply({"unknown": CANARY})
        expected = "Basic " + base64.b64encode(b"admin:packtest-canary-grafana-61df").decode()
        auth_ok = self.headers.get("Authorization") == expected
        OBSERVED.append({"path": url.path, "query": query, "auth_ok": auth_ok})
        if not auth_ok:
            return self.reply({"message": "invalid credentials"}, 401)
        is_rules = url.path == "/api/prometheus/grafana/api/v1/rules"
        if not is_rules and url.path != "/api/frontend/settings":
            return self.reply({"message": "unknown fixture path"}, 404)
        value = rules() if is_rules else version()
        if MODE == "http-error":
            return self.reply({"message": "fixture scope denied"}, 403)
        if MODE == "redirect":
            return self.reply({"unknown": CANARY}, 302, location="/redirected")
        if MODE == "transport":
            return self.reply(value, extra_length=100)
        if MODE == "oversize-raw":
            value["unknown"] = "x" * 4194304
        elif MODE == "bad-json":
            return self.reply(b'{"incomplete":')
        elif MODE == "multiple-json":
            return self.reply(b"{}\n{}")
        elif MODE == "wrong-root":
            return self.reply([])
        elif is_rules:
            data = value["data"]
            group = data["groups"][0]
            rule = group["rules"][0]
            if MODE == "empty":
                value = {"status": "success", "data": {"groups": []}}
            elif MODE == "wrong-status":
                value["status"] = "error"
            elif MODE == "continuation":
                data["groupNextToken"] = "must-not-drop-page"
            elif MODE == "bad-cursor":
                data["groupNextToken"] = 12
            elif MODE == "wrong-groups":
                data["groups"] = {}
            elif MODE == "wrong-rules":
                group["rules"] = {}
            elif MODE == "wrong-labels":
                rule["labels"] = {"team": {"unknown": CANARY}}
            elif MODE == "wrong-rule":
                rule["isPaused"] = "false"
            elif MODE == "wrong-totals":
                data["totals"] = {"firing": -1}
            elif MODE in ("near-output", "over-output"):
                # UTF-8 labels are retained completely, never clipped to fit.
                count = 65000 if MODE == "near-output" else 66000
                rule["labels"]["large"] = "𐐨" * count + "END"
            elif MODE == "many-rules":
                group["rules"] = [dict(rule, uid=f"rule-{i}") for i in range(200)]
                group["totals"] = {"firing": 200, "error": 200}
                data["totals"] = {"firing": 200, "error": 200}
        else:
            if MODE == "wrong-build":
                value["buildInfo"] = []
            elif MODE == "wrong-license":
                value["licenseInfo"] = []
            elif MODE == "wrong-version":
                value["buildInfo"]["version"] = 13
            elif MODE == "wrong-expiry":
                value["licenseInfo"]["expiry"] = "0"
            elif MODE in ("near-output", "over-output"):
                count = 1900 if MODE == "near-output" else 2100
                value["licenseInfo"]["stateInfo"] = "𐐨" * count + "END"
        return self.reply(value)


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
