#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from uuid import UUID


API_TOKEN = "packtest-canary-sentry-token-51c2"
KEY_SECRET = "packtest-canary-sentry-key-secret-77aa"

ORG = "acme"
PROJECT = "backend"
ISSUE_ONE = "1234567890"
ISSUE_TWO = "1234567891"
ISSUE_LOG = "1234567892"
ISSUE_OVERSIZED = "1234567893"
ISSUE_FILTERED = "1234567894"
OLDER_EVENT_ID = "feedfacefeedfacefeedfacefeedface"
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


def stacktrace(count, filename="app/checkout.py", function="confirm"):
    return {
        "frames": [
            {
                "filename": filename,
                "function": function,
                "lineNo": 218 + index,
                "inApp": index > 0,
                "vars": {"session": "private-frame-local"},
            }
            for index in range(count)
        ],
    }


def issue_event(event_id, date_created, item_id, environment="production"):
    return {
        "eventID": event_id,
        "dateCreated": date_created,
        "message": "Checkout failed",
        "title": "CheckoutError",
        "user": {"id": "customer-101"},
        "tags": [
            {"key": "environment", "value": environment},
            {"key": "release", "value": "2.1.0"},
        ],
        "contexts": {"cart": {"item_id": item_id}},
        "context": {"attempt": 3},
        "entries": [
            {"type": "stacktrace", "data": stacktrace(6)},
            {"type": "breadcrumbs", "data": {"values": [{"message": "private-breadcrumb"}]}},
        ],
    }


def older_issue_event():
    event = issue_event(OLDER_EVENT_ID, "2026-08-11T19:55:00Z", "cart-18")
    event.update(message="", title="CartUnavailable: Checkout could not continue", user=None, tags=[], context={})
    return event


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

    def list_issue_events(self, path, query):
        limit = int(query.get("per_page", ["0"])[0])
        if query.get("full") != ["true"] or not 1 <= limit <= 10:
            self.send_json({"detail": "full=true and a bounded per_page are required"}, 400)
            return
        if path.endswith(f"/{ISSUE_TWO}/events/"):
            self.send_json([])
            return
        if path.endswith(f"/{ISSUE_OVERSIZED}/events/"):
            self.send_json([{"context": {"item_id": "x" * (1024 * 1024)}}])
            return

        latest = issue_event("f00dfeedf00dfeedf00dfeedf00dfeed", "2026-08-11T20:00:00Z", "cart-42")
        events = [latest, older_issue_event()]
        if path.endswith(f"/{ISSUE_FILTERED}/events/"):
            events = [
                issue_event("a" * 32, "2026-08-11T20:02:00Z", "cart-staging", "staging"),
                issue_event("b" * 32, "2026-08-11T20:00:00Z", "cart-42"),
                issue_event("c" * 32, "2026-08-11T19:55:00Z", "cart-18"),
                issue_event("d" * 32, "2026-08-11T19:00:00Z", "cart-yesterday"),
            ]

        if "environment" in query:
            events = [
                event for event in events
                if any(tag["key"] == "environment" and tag["value"] in query["environment"] for tag in event["tags"])
            ]
        if "start" in query or "end" in query:
            if "start" not in query or "end" not in query or query["start"][0] >= query["end"][0]:
                self.send_json({"detail": "start and end must form a valid window"}, 400)
                return
            start, end = query["start"][0], query["end"][0]
            events = [event for event in events if start <= event["dateCreated"] < end]

        offset = 1 if query.get("cursor") == ["0:1:0"] else 0
        end = offset + limit
        self.send_json(events[offset:end], link=self.link_header(path, f"0:{end}:0", end < len(events)))

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
            if query.get("query") == ["worst_case"]:
                flood = ('"\\\x01pwd=x' * 200)
                ordered = [
                    issue(str(1234567800 + index), flood, flood, "9" * 20, "8" * 20)
                    for index in range(8)
                ]
            else:
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
        if path in {
            f"/api/0/organizations/{ORG}/issues/{issue_id}/events/"
            for issue_id in (ISSUE_ONE, ISSUE_TWO, ISSUE_OVERSIZED, ISSUE_FILTERED)
        }:
            self.list_issue_events(path, query)
            return
        if path == f"/api/0/organizations/{ORG}/issues/{ISSUE_LOG}/events/latest/":
            self.send_json(
                {
                    "eventID": "feedfacefeedfacefeedfacefeedface",
                    "dateCreated": "2026-08-11T20:01:00Z",
                    "platform": "python",
                    "message": "",
                    "entries": [
                        {
                            "type": "message",
                            "data": {
                                "formatted": "Cart 42 is still pending",
                                "message": "Cart %d is still pending",
                                "params": [42],
                            },
                        },
                        {"type": "stacktrace", "data": stacktrace(6, function="log_pending")},
                        {
                            "type": "threads",
                            "data": {
                                "values": [
                                    {"id": 1, "current": True, "stacktrace": stacktrace(5, function="worker")},
                                ],
                            },
                        },
                    ],
                    "contexts": {"cart": {"items": [{"sku": "A42", "amount": 2}]}},
                    "context": {"attempt": 3},
                    "tags": [
                        {"key": "release", "value": "2.1.0"},
                        {"key": "environment", "value": "production"},
                        {"key": "browser", "value": "Firefox"},
                        {"key": "level", "value": "warning"},
                        {"key": "feature", "value": "checkout"},
                    ],
                }
            )
            return
        if path == f"/api/0/organizations/{ORG}/issues/{ISSUE_OVERSIZED}/events/latest/":
            self.send_json({"contexts": {"oversized": {"description": "x" * (1024 * 1024)}}})
            return
        if path in {
            f"/api/0/organizations/{ORG}/issues/{ISSUE_ONE}/events/latest/",
            f"/api/0/organizations/{ORG}/issues/{ISSUE_TWO}/events/latest/",
        }:
            worst_case = path.endswith(f"/{ISSUE_TWO}/events/latest/")
            exception_values = [
                {
                    "type": "TypeError",
                    "value": "cannot read frames of undefined",
                    "stacktrace": stacktrace(48, filename="app/" + "nested/" * 20 + "checkout.py")
                    if worst_case
                    else stacktrace(6),
                }
                for _ in range(3 if worst_case else 1)
            ]
            breadcrumbs = [
                {
                    "category": "query",
                    "message": f"Authorization: Bearer {API_TOKEN}"
                    if index == 1
                    else "SELECT * FROM carts WHERE id = %s",
                    "level": "info",
                    "timestamp": "2026-08-11T20:00:00Z",
                }
                for index in range(8 if worst_case else 2)
            ]
            self.send_json(
                {
                    "eventID": "f00dfeedf00dfeedf00dfeedf00dfeed",
                    "dateCreated": "2026-08-11T20:00:00Z",
                    "platform": "python",
                    "message": "Checkout failed",
                    "entries": [
                        {
                            "type": "exception",
                            "data": {"values": exception_values},
                        },
                        {
                            "type": "breadcrumbs",
                            "data": {"values": breadcrumbs},
                        },
                        {
                            "type": "request",
                            "data": {
                                "method": "POST",
                                "url": "https://shop.example.test/checkout",
                                "query": [["cart", "42"]],
                                "headers": [["Authorization", f"Bearer {API_TOKEN}"]],
                                "cookies": [["session", "private-request-cookie"]],
                                "data": {"password": 'quote"slash\\secret'},
                            },
                        },
                    ],
                    "contexts": {"runtime": {"name": "CPython", "version": "3.12.4"}},
                    "tags": [{"key": "release", "value": "2.1.0"}],
                    "_meta": {"password": 'quote"slash\\secret'},
                }
            )
            return
        event_path = f"/api/0/organizations/{ORG}/issues/{ISSUE_ONE}/events/"
        if path in {f"{event_path}{OLDER_EVENT_ID}/", f"{event_path}{UUID(OLDER_EVENT_ID)}/"}:
            self.send_json(older_issue_event())
            return
        if path.startswith(event_path):
            self.send_json({"detail": "Event not found."}, 404)
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
        if path == f"/api/0/organizations/{ORG}/workflows/":
            if "project" not in query or "per_page" not in query:
                self.send_json({"detail": "project and per_page are required"}, 400)
                return
            if query["project"] == ["forbidden"]:
                self.send_json({"detail": "You do not have permission to perform this action."}, 403)
                return
            if query["project"] == ["empty"]:
                self.send_json([], link=self.link_header(path, "0:0:0", False))
                return
            if query["project"] != [PROJECT]:
                self.send_json({"detail": "The requested project does not exist"}, 404)
                return
            alerts = [
                {
                    "id": "9001",
                    "name": "High volume",
                    "enabled": True,
                    "triggers": {"logicType": "any-short", "conditions": [{"type": "event_frequency_count", "comparison": 100}]},
                    "actionFilters": [{"logicType": "all", "conditions": [], "actions": [{"type": "email", "config": {"targetType": "team", "targetIdentifier": "12"}}]}],
                    "config": {"frequency": 30},
                    "detectorIds": ["7001"],
                },
                {"id": "9002", "name": "New high-priority issue", "enabled": False, "triggers": {"conditions": []}, "actionFilters": [], "config": {"frequency": 60}, "detectorIds": ["7001"]},
            ]
            limit = int(query["per_page"][0])
            if not 1 <= limit <= 100:
                self.send_json({"detail": "Invalid per_page"}, 400)
                return
            offset = 1 if query.get("cursor") == [NEXT_CURSOR] else 0
            self.send_json(
                alerts[offset:offset + limit],
                link=self.link_header(path, NEXT_CURSOR, offset + limit < len(alerts)),
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
