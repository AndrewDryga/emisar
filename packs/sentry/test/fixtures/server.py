#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


API_TOKEN = "packtest-canary-sentry-token-51c2"
KEY_SECRET = "packtest-canary-sentry-key-secret-77aa"

ORG = "acme"
PROJECT = "backend"
ISSUE_ONE = "1234567890"
ISSUE_TWO = "1234567891"
KEY_ID = "cec9dfceb0b74c1c9a5e3c135585f364"
NEXT_CURSOR = "1700000000000:1:0"


def issue(issue_id, title, culprit, count, user_count):
    return {
        "id": issue_id,
        "shortId": f"BACKEND-{issue_id[-2:]}",
        "title": title,
        "culprit": culprit,
        "level": "error",
        "status": "unresolved",
        "assignedTo": None,
        "count": count,
        "userCount": user_count,
        "firstSeen": "2026-08-09T08:00:00Z",
        "lastSeen": "2026-08-11T20:00:00Z",
        "project": {"id": "11", "slug": PROJECT},
    }


STATE = {
    "issues": {
        ISSUE_ONE: issue(ISSUE_ONE, "TypeError: cannot read frames of undefined", "app/checkout.py in confirm", "4821", "312"),
        ISSUE_TWO: issue(ISSUE_TWO, "ConnectionError: redis pool exhausted", "app/cache.py in get", "957", "88"),
    },
    "key": {
        "id": KEY_ID,
        "name": "Default",
        "label": "Default",
        "public": "8f4b2a1c9d0e8f7a6b5c4d3e2f1a0b9c",
        "secret": KEY_SECRET,
        "isActive": True,
        "dsn": {
            "public": f"http://8f4b2a1c9d0e8f7a6b5c4d3e2f1a0b9c@sentry.example.test/11",
            "secret": f"http://8f4b2a1c9d0e8f7a6b5c4d3e2f1a0b9c:{KEY_SECRET}@sentry.example.test/11",
            "csp": "http://sentry.example.test/api/11/csp-report/",
        },
        "rateLimit": {"window": 60, "count": 1000},
        "dateCreated": "2026-05-01T10:00:00Z",
    },
    "events": [],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def send_json(self, value, status=200, link=None):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if link is not None:
            self.send_header("Link", link)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def link_header(self, path, next_cursor, has_more):
        base = f"http://sentry-api:8080{path}"
        previous = f'<{base}?cursor=0:0:1>; rel="previous"; results="false"; cursor="0:0:1"'
        more = "true" if has_more else "false"
        upcoming = f'<{base}?cursor={next_cursor}>; rel="next"; results="{more}"; cursor="{next_cursor}"'
        return f"{previous}, {upcoming}"

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {API_TOKEN}":
            return True
        self.send_json({"detail": "Invalid token"}, 401)
        return False

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health":
            self.send_json({"ok": True})
            return
        if path == "/probe/state":
            self.send_json(STATE)
            return
        if not self.authorized():
            return

        if path == "/api/0/organizations/":
            self.send_json(
                [{"id": "1", "slug": ORG, "name": "Acme", "isEarlyAdopter": False}],
                link=self.link_header(path, "0:100:0", False),
            )
            return
        if path == f"/api/0/organizations/{ORG}/projects/":
            self.send_json(
                [{"id": "11", "slug": PROJECT, "name": "Backend", "platform": "python", "status": "active"}],
                link=self.link_header(path, "0:100:0", False),
            )
            return
        if path == f"/api/0/projects/{ORG}/{PROJECT}/issues/":
            if "query" not in query or "statsPeriod" not in query or "sort" not in query:
                self.send_json({"detail": "missing query parameters"}, 400)
                return
            ordered = [STATE["issues"][ISSUE_ONE], STATE["issues"][ISSUE_TWO]]
            limit = int(query.get("limit", ["25"])[0])
            cursor = query.get("cursor", [""])[0]
            if cursor == NEXT_CURSOR:
                window, has_more = ordered[1:][:limit], False
            else:
                window = ordered[:limit]
                has_more = limit < len(ordered)
            self.send_json(window, link=self.link_header(path, NEXT_CURSOR, has_more))
            return
        if path == f"/api/0/organizations/{ORG}/issues/{ISSUE_ONE}/":
            self.send_json(STATE["issues"][ISSUE_ONE])
            return
        if path == f"/api/0/organizations/{ORG}/issues/{ISSUE_ONE}/events/latest/":
            self.send_json(
                {
                    "eventID": "f00dfeedf00dfeedf00dfeedf00dfeed",
                    "dateCreated": "2026-08-11T20:00:00Z",
                    "platform": "python",
                    "entries": [
                        {
                            "type": "exception",
                            "data": {
                                "values": [
                                    {
                                        "type": "TypeError",
                                        "value": "cannot read frames of undefined",
                                        "stacktrace": {
                                            "frames": [
                                                {"filename": "app/checkout.py", "function": "confirm", "lineNo": 218},
                                                {"filename": "app/cart.py", "function": "total", "lineNo": 77},
                                            ]
                                        },
                                    }
                                ]
                            },
                        },
                        {
                            "type": "breadcrumbs",
                            "data": {"values": [{"category": "query", "message": "SELECT * FROM carts WHERE id = %s", "level": "info"}]},
                        },
                    ],
                    "contexts": {"runtime": {"name": "CPython", "version": "3.12.4"}},
                    "tags": [{"key": "release", "value": "2.1.0"}],
                }
            )
            return
        if path == f"/api/0/organizations/{ORG}/issues/{ISSUE_ONE}/tags/":
            self.send_json(
                [
                    {"key": "release", "uniqueValues": 2, "topValues": [{"value": "2.1.0", "count": 3200}]},
                    {"key": "environment", "uniqueValues": 1, "topValues": [{"value": "production", "count": 4821}]},
                ]
            )
            return
        if path == f"/api/0/organizations/{ORG}/releases/":
            self.send_json(
                [
                    {"version": "2.1.0", "dateCreated": "2026-08-11T07:00:00Z", "newGroups": 12, "projects": [{"slug": PROJECT}]},
                    {"version": "2.0.9", "dateCreated": "2026-08-04T07:00:00Z", "newGroups": 1, "projects": [{"slug": PROJECT}]},
                ],
                link=self.link_header(path, "0:100:0", False),
            )
            return
        if path == f"/api/0/projects/{ORG}/{PROJECT}/keys/":
            self.send_json([STATE["key"]])
            return
        if path == f"/api/0/organizations/{ORG}/stats_v2/":
            expected = {"field": ["sum(quantity)"], "groupBy": ["category", "outcome"]}
            if query.get("field") != expected["field"] or sorted(query.get("groupBy", [])) != expected["groupBy"]:
                self.send_json({"detail": "unexpected stats query"}, 400)
                return
            self.send_json(
                {
                    "start": "2026-08-10T21:00:00Z",
                    "end": "2026-08-11T21:00:00Z",
                    "intervals": ["2026-08-11T20:00:00Z"],
                    "groups": [
                        {"by": {"category": "error", "outcome": "accepted"}, "totals": {"sum(quantity)": 90000}, "series": {"sum(quantity)": [90000]}},
                        {"by": {"category": "error", "outcome": "rate_limited"}, "totals": {"sum(quantity)": 1200}, "series": {"sum(quantity)": [1200]}},
                    ],
                }
            )
            return
        if path == f"/api/0/projects/{ORG}/{PROJECT}/rules/":
            self.send_json(
                [
                    {
                        "id": "9001",
                        "name": "High volume",
                        "conditions": [{"id": "sentry.rules.conditions.event_frequency.EventFrequencyCondition", "value": 100}],
                        "actions": [{"id": "sentry.mail.actions.NotifyEmailAction", "targetType": "Team"}],
                        "frequency": 30,
                    }
                ]
            )
            return

        self.send_json({"detail": "The requested resource does not exist"}, 404)

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if not self.authorized():
            return
        body = self.read_json()

        for issue_id in (ISSUE_ONE, ISSUE_TWO):
            if path == f"/api/0/organizations/{ORG}/issues/{issue_id}/":
                record = STATE["issues"][issue_id]
                if "status" in body:
                    record["status"] = body["status"]
                    STATE["events"].append(f'issue_status:{issue_id}={body["status"]}')
                    minutes = body.get("statusDetails", {}).get("ignoreDuration")
                    if minutes is not None:
                        STATE["events"].append(f"ignore_duration:{issue_id}={minutes}")
                if "assignedTo" in body:
                    record["assignedTo"] = body["assignedTo"]
                    STATE["events"].append(f'issue_assigned:{issue_id}={body["assignedTo"]}')
                self.send_json(record)
                return
        if path == f"/api/0/projects/{ORG}/{PROJECT}/keys/{KEY_ID}/":
            if "isActive" not in body or not isinstance(body["isActive"], bool):
                self.send_json({"detail": "expected a boolean isActive"}, 400)
                return
            STATE["key"]["isActive"] = body["isActive"]
            STATE["events"].append(f'key_active:{str(body["isActive"]).lower()}')
            self.send_json(STATE["key"])
            return

        self.send_json({"detail": "The requested resource does not exist"}, 404)


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
