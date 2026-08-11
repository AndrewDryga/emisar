#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


API_TOKEN = "packtest-canary-cloudflare-token-9f3e2"

ZONE_ID = "abc123def456abc123def456abc123de"
ACCOUNT_ID = "9f8e7d6c5b4a39281706f5e4d3c2b1a0"
RECORD_A = "372e67954025e0ba6aaa6d586b9e0b59"
RECORD_TXT = "7d2e3c4b5a69788796a5b4c3d2e1f012"
RECORD_MX = "5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f"
NEW_RECORD = "b1c2d3e4f5a60718293a4b5c6d7e8f90"
ACCESS_RULE = "92f17202ed8bd63d69a66b86a49a8f6b"
NEW_ACCESS_RULE = "1a2b3c4d5e6f70819203a4b5c6d7e8f9"
TUNNEL_ID = "f70a3b21-9c86-4dcb-8d5e-1f2a3b4c5d6e"
POOL_ID = "17b5962d775c646f3f9725cbc7a53df4"
LB_ID = "699d98642c564d2e855e9661899b7252"
RULESET_ID = "2f2c8545e5e5493d96b8fd7bf8c56f2a"
ROUTE_ID = "e7a57d8746e74ae49c25994dadb421b1"
NEW_ROUTE = "f1e2d3c4b5a6978800112233445566aa"
PAGES_PROJECT = "marketing-site"
DEPLOY_LIVE = "aaaabbbb-cccc-4ddd-8eee-ffff00001111"
DEPLOY_PREV = "bbbbcccc-dddd-4eee-8fff-000011112222"
DEPLOY_FAILED = "ccccdddd-eeee-4fff-8000-111122223333"


def initial_state():
    return {
        "zone": {
            "id": ZONE_ID,
            "name": "example.test",
            "status": "active",
            "paused": False,
            "type": "full",
            "development_mode": 0,
            "name_servers": ["ada.ns.cloudflare.test", "bob.ns.cloudflare.test"],
            "original_name_servers": ["ns1.example.test", "ns2.example.test"],
            "plan": {"id": "free", "name": "Free Website", "legacy_id": "free"},
            "account": {"id": ACCOUNT_ID, "name": "Fixture Org"},
            "created_on": "2026-05-01T10:00:00Z",
            "modified_on": "2026-08-01T10:00:00Z",
        },
        "settings": {
            "always_use_https": "off",
            "browser_cache_ttl": 14400,
            "cache_level": "aggressive",
            "development_mode": "off",
            "min_tls_version": "1.2",
            "security_level": "medium",
            "ssl": "full",
        },
        "dns_records": [
            {
                "id": RECORD_A,
                "type": "A",
                "name": "www.example.test",
                "content": "203.0.113.10",
                "ttl": 1,
                "proxied": True,
                "comment": "primary web frontend",
            },
            {
                "id": RECORD_TXT,
                "type": "TXT",
                "name": "example.test",
                "content": "v=spf1 include:_spf.example.test ~all",
                "ttl": 3600,
                "proxied": False,
            },
            {
                "id": RECORD_MX,
                "type": "MX",
                "name": "example.test",
                "content": "mail.example.test",
                "priority": 10,
                "ttl": 3600,
                "proxied": False,
            },
        ],
        "access_rules": [
            {
                "id": ACCESS_RULE,
                "mode": "block",
                "configuration": {"target": "ip", "value": "198.51.100.99"},
                "notes": "fixture block",
                "created_on": "2026-08-01T10:00:00Z",
            }
        ],
        "pool": {
            "id": POOL_ID,
            "name": "origin-pool-a",
            "enabled": True,
            "healthy": True,
            "monitor": "9004c07f1c0f33255410e45590251cf4",
            "origins": [
                {"name": "origin-1", "address": "198.51.100.10", "enabled": True, "weight": 1, "healthy": True},
                {"name": "origin-2", "address": "198.51.100.11", "enabled": True, "weight": 1, "healthy": False},
            ],
        },
        "worker_routes": [
            {"id": ROUTE_ID, "pattern": "example.test/api/*", "script": "api-worker"}
        ],
        "purges": [],
        "events": [],
    }


def pages_deployment(deployment_id, environment, stage_name, stage_status, branch):
    return {
        "id": deployment_id,
        "environment": environment,
        "url": f"https://{deployment_id[:8]}.{PAGES_PROJECT}.pages.test",
        "created_on": "2026-08-10T09:00:00Z",
        "latest_stage": {"name": stage_name, "status": stage_status},
        "deployment_trigger": {"type": "push", "metadata": {"branch": branch, "commit_hash": "4f2d9c1"}},
        "source": {"type": "github"},
    }


PAGES_DEPLOYMENTS = [
    pages_deployment(DEPLOY_LIVE, "production", "deploy", "success", "main"),
    pages_deployment(DEPLOY_PREV, "production", "deploy", "success", "main"),
    pages_deployment(DEPLOY_FAILED, "preview", "build", "failure", "fix/navigation"),
]


STATE = initial_state()


def paginate(items, query):
    page = int(query.get("page", ["1"])[0])
    per_page = int(query.get("per_page", ["50"])[0])
    start = (page - 1) * per_page
    window = items[start : start + per_page]
    info = {"page": page, "per_page": per_page, "count": len(window), "total_count": len(items)}
    return window, info


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def send_json(self, value, status=200):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_ok(self, result, result_info=None):
        envelope = {"success": True, "errors": [], "messages": [], "result": result}
        if result_info is not None:
            envelope["result_info"] = result_info
        self.send_json(envelope)

    def send_err(self, status, code, message):
        self.send_json({"success": False, "errors": [{"code": code, "message": message}], "messages": [], "result": None}, status)

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {API_TOKEN}":
            return True
        self.send_err(403, 9109, "Invalid access token")
        return False

    def zone_guard(self, zone_id):
        if zone_id == ZONE_ID:
            return True
        self.send_err(404, 1001, "Invalid zone identifier")
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

        if path == "/client/v4/zones":
            zones = [STATE["zone"]]
            name = query.get("name", [""])[0]
            status = query.get("status", [""])[0]
            if name:
                zones = [zone for zone in zones if zone["name"] == name]
            if status:
                zones = [zone for zone in zones if zone["status"] == status]
            window, info = paginate(zones, query)
            self.send_ok(window, info)
            return
        if path == "/client/v4/accounts":
            window, info = paginate([{"id": ACCOUNT_ID, "name": "Fixture Org", "type": "standard"}], query)
            self.send_ok(window, info)
            return

        parts = path.removeprefix("/client/v4/").split("/")

        if parts[0] == "zones" and len(parts) >= 2:
            zone_id = parts[1]
            if not self.zone_guard(zone_id):
                return
            rest = parts[2:]
            if not rest:
                self.send_ok(STATE["zone"])
                return
            if rest == ["settings"]:
                settings = [
                    {"id": key, "value": value, "editable": True, "modified_on": "2026-08-01T10:00:00Z"}
                    for key, value in sorted(STATE["settings"].items())
                ]
                self.send_ok(settings)
                return
            if rest == ["dns_records"]:
                records = STATE["dns_records"]
                record_type = query.get("type", [""])[0]
                name = query.get("name", [""])[0]
                content = query.get("content", [""])[0]
                if record_type:
                    records = [record for record in records if record["type"] == record_type]
                if name:
                    records = [record for record in records if record["name"] == name]
                if content:
                    records = [record for record in records if record["content"] == content]
                window, info = paginate(records, query)
                self.send_ok(window, info)
                return
            if rest == ["rulesets"]:
                self.send_ok(
                    [
                        {"id": RULESET_ID, "name": "zone", "kind": "zone", "phase": "http_request_firewall_custom", "version": "3"},
                        {
                            "id": "4d6f8a2b1c0e9d8f7a6b5c4d3e2f1a0b",
                            "name": "Cloudflare Managed Ruleset",
                            "kind": "managed",
                            "phase": "http_request_firewall_managed",
                            "version": "12",
                        },
                    ]
                )
                return
            if rest == ["rulesets", "phases", "http_request_firewall_custom", "entrypoint"]:
                self.send_ok(
                    {
                        "id": RULESET_ID,
                        "name": "zone",
                        "kind": "zone",
                        "phase": "http_request_firewall_custom",
                        "rules": [
                            {
                                "id": "8ac7b3f2e1d0c9b8a7f6e5d4c3b2a190",
                                "action": "block",
                                "expression": "(ip.src eq 198.51.100.99)",
                                "description": "fixture block rule",
                                "enabled": True,
                            }
                        ],
                        "last_updated": "2026-08-01T10:00:00Z",
                    }
                )
                return
            if rest == ["firewall", "access_rules", "rules"]:
                rules = STATE["access_rules"]
                mode = query.get("mode", [""])[0]
                if mode:
                    rules = [rule for rule in rules if rule["mode"] == mode]
                window, info = paginate(rules, query)
                self.send_ok(window, info)
                return
            if rest == ["ssl", "verification"]:
                self.send_ok(
                    [
                        {
                            "certificate_status": "active",
                            "validation_method": "txt",
                            "verification_type": "cname",
                            "cert_pack_uuid": "a77f8bd7-3b47-46b4-a6f1-75cf98109948",
                            "hostname": "example.test",
                            "brand_check": False,
                            "verification_status": True,
                        }
                    ]
                )
                return
            if rest == ["ssl", "certificate_packs"]:
                self.send_ok(
                    [
                        {
                            "id": "a77f8bd7-3b47-46b4-a6f1-75cf98109948",
                            "type": "advanced",
                            "hosts": ["example.test", "*.example.test"],
                            "status": "active",
                            "certificates": [
                                {
                                    "id": "3c2b1a0f9e8d7c6b5a49382716053f4e",
                                    "issuer": "FixtureCA",
                                    "expires_on": "2026-11-08T12:00:00Z",
                                    "hosts": ["example.test", "*.example.test"],
                                    "status": "active",
                                }
                            ],
                        }
                    ]
                )
                return
            if rest == ["pagerules"]:
                self.send_ok(
                    [
                        {
                            "id": "9a7806061c88ada191ed06f989cc3dac",
                            "targets": [{"target": "url", "constraint": {"operator": "matches", "value": "http://*.example.test/*"}}],
                            "actions": [{"id": "always_use_https"}],
                            "priority": 1,
                            "status": "active",
                        }
                    ]
                )
                return
            if rest == ["workers", "routes"]:
                self.send_ok(STATE["worker_routes"])
                return
            if rest == ["load_balancers"]:
                self.send_ok(
                    [
                        {
                            "id": LB_ID,
                            "name": "lb.example.test",
                            "fallback_pool": POOL_ID,
                            "default_pools": [POOL_ID],
                            "proxied": True,
                            "enabled": True,
                            "steering_policy": "dynamic_latency",
                        }
                    ]
                )
                return
            if rest == ["dns_analytics", "report"]:
                if not query.get("since") or not query.get("until"):
                    self.send_err(400, 6008, "missing since/until")
                    return
                self.send_ok(
                    {
                        "rows": 2,
                        "data": [
                            {"dimensions": ["www.example.test", "A", "NOERROR"], "metrics": [1200]},
                            {"dimensions": ["example.test", "MX", "NOERROR"], "metrics": [300]},
                        ],
                        "totals": {"queryCount": 1500},
                        "min": {"queryCount": 300},
                        "max": {"queryCount": 1200},
                        "query": {"limit": int(query.get("limit", ["20"])[0])},
                    }
                )
                return

        if parts[0] == "accounts" and len(parts) >= 2:
            if parts[1] != ACCOUNT_ID:
                self.send_err(404, 7003, "Could not route to account")
                return
            rest = parts[2:]
            if rest == ["audit_logs"]:
                if not query.get("since"):
                    self.send_err(400, 6008, "missing since")
                    return
                window, info = paginate(
                    [
                        {
                            "id": "d5b0f326-1232-4452-8858-1089bd7168ef",
                            "action": {"type": "rec_add", "result": True},
                            "actor": {"email": "ops@example.test", "type": "user", "ip": "198.51.100.7"},
                            "when": "2026-08-11T09:14:00Z",
                            "resource": {"type": "DNS_record", "id": RECORD_A},
                            "interface": "API",
                            "metadata": {"zone_name": "example.test"},
                        }
                    ],
                    query,
                )
                self.send_ok(window, info)
                return
            if rest == ["cfd_tunnel"]:
                if query.get("is_deleted", [""])[0] != "false":
                    self.send_err(400, 6008, "expected is_deleted=false")
                    return
                window, info = paginate(
                    [
                        {
                            "id": TUNNEL_ID,
                            "account_tag": ACCOUNT_ID,
                            "name": "prod-edge",
                            "status": "healthy",
                            "created_at": "2026-05-01T10:00:00Z",
                            "conns_active_at": "2026-08-11T08:00:00Z",
                            "remote_config": True,
                        }
                    ],
                    query,
                )
                self.send_ok(window, info)
                return
            if rest == ["cfd_tunnel", TUNNEL_ID, "connections"]:
                self.send_ok(
                    [
                        {
                            "id": "c3f5a1b2-4d6e-4f80-9a1b-2c3d4e5f6071",
                            "version": "2026.7.0",
                            "arch": "linux_amd64",
                            "config_version": 7,
                            "run_at": "2026-08-11T08:00:00Z",
                            "conns": [
                                {"colo_name": "FRA", "is_pending_reconnect": False, "opened_at": "2026-08-11T08:00:00Z", "origin_ip": "198.51.100.7"},
                                {"colo_name": "AMS", "is_pending_reconnect": False, "opened_at": "2026-08-11T08:00:01Z", "origin_ip": "198.51.100.7"},
                            ],
                        }
                    ]
                )
                return
            if rest == ["workers", "scripts"]:
                self.send_ok(
                    [
                        {
                            "id": "api-worker",
                            "etag": "8d3c2b1a0f9e8d7c6b5a4938271605f4",
                            "created_on": "2026-05-01T10:00:00Z",
                            "modified_on": "2026-08-10T09:00:00Z",
                            "usage_model": "standard",
                        }
                    ]
                )
                return
            if rest == ["workers", "scripts", "api-worker", "deployments"]:
                self.send_ok(
                    {
                        "deployments": [
                            {
                                "id": "0d3c4e5f-6a7b-4c9d-8e1f-2a3b4c5d6e7f",
                                "source": "api",
                                "strategy": "percentage",
                                "author_email": "ops@example.test",
                                "created_on": "2026-08-10T09:00:00Z",
                                "versions": [{"version_id": "11111111-2222-4333-8444-555555555555", "percentage": 100}],
                            }
                        ]
                    }
                )
                return
            if rest == ["pages", "projects"]:
                window, info = paginate(
                    [
                        {
                            "id": "7b9c1d2e-3f40-4a5b-8c6d-9e0f1a2b3c4d",
                            "name": PAGES_PROJECT,
                            "subdomain": f"{PAGES_PROJECT}.pages.test",
                            "domains": ["www.example.test"],
                            "production_branch": "main",
                            "created_on": "2026-05-01T10:00:00Z",
                            "latest_deployment": {"id": DEPLOY_LIVE, "environment": "production"},
                        }
                    ],
                    query,
                )
                self.send_ok(window, info)
                return
            if rest == ["pages", "projects", PAGES_PROJECT, "deployments"]:
                deployments = PAGES_DEPLOYMENTS
                environment = query.get("env", [""])[0]
                if environment:
                    deployments = [item for item in deployments if item["environment"] == environment]
                window, info = paginate(deployments, query)
                self.send_ok(window, info)
                return
            if rest == ["pages", "projects", PAGES_PROJECT, "deployments", DEPLOY_FAILED, "history", "logs"]:
                self.send_ok(
                    {
                        "total": 3,
                        "include_container_logs": True,
                        "data": [
                            {"ts": "2026-08-10T09:00:01Z", "line": "Installing dependencies"},
                            {"ts": "2026-08-10T09:00:09Z", "line": "npm ERR! missing script: build"},
                            {"ts": "2026-08-10T09:00:10Z", "line": "Failed: build command exited with code 1"},
                        ],
                    }
                )
                return
            if rest == ["load_balancers", "pools"]:
                self.send_ok([STATE["pool"]])
                return
            if rest == ["load_balancers", "pools", POOL_ID, "health"]:
                self.send_ok(
                    {
                        "pool_id": POOL_ID,
                        "pop_health": {
                            "Amsterdam, NL": {
                                "healthy": True,
                                "origins": [
                                    {"198.51.100.10": {"healthy": True, "failure_reason": "", "response_code": 200, "rtt": "12.1ms"}},
                                    {"198.51.100.11": {"healthy": False, "failure_reason": "connection timeout", "response_code": 0, "rtt": "0ms"}},
                                ],
                            }
                        },
                    }
                )
                return

        self.send_err(404, 7000, "No route for that URI")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if not self.authorized():
            return

        if path == "/client/v4/graphql":
            body = self.read_json()
            variables = body.get("variables", {})
            if variables.get("zone") != ZONE_ID or "httpRequests1hGroups" not in body.get("query", ""):
                self.send_json({"data": None, "errors": [{"message": "zone not found"}]})
                return
            self.send_json(
                {
                    "data": {
                        "viewer": {
                            "zones": [
                                {
                                    "httpRequests1hGroups": [
                                        {
                                            "dimensions": {"datetime": "2026-08-11T08:00:00Z"},
                                            "sum": {
                                                "requests": 52000,
                                                "bytes": 9800000000,
                                                "cachedRequests": 41000,
                                                "cachedBytes": 8100000000,
                                                "threats": 120,
                                                "pageViews": 30000,
                                            },
                                            "uniq": {"uniques": 8000},
                                        },
                                        {
                                            "dimensions": {"datetime": "2026-08-11T09:00:00Z"},
                                            "sum": {
                                                "requests": 48000,
                                                "bytes": 9100000000,
                                                "cachedRequests": 39000,
                                                "cachedBytes": 7600000000,
                                                "threats": 80,
                                                "pageViews": 27000,
                                            },
                                            "uniq": {"uniques": 7600},
                                        },
                                    ]
                                }
                            ]
                        }
                    }
                }
            )
            return

        parts = path.removeprefix("/client/v4/").split("/")
        if parts[0] == "zones" and len(parts) >= 3:
            zone_id = parts[1]
            if not self.zone_guard(zone_id):
                return
            rest = parts[2:]
            body = self.read_json()
            if rest == ["purge_cache"]:
                scopes = [key for key in ("purge_everything", "files", "hosts", "tags", "prefixes") if key in body]
                if len(scopes) != 1:
                    self.send_err(400, 1012, "exactly one purge scope required")
                    return
                scope = scopes[0]
                values = True if scope == "purge_everything" else body[scope]
                if scope != "purge_everything" and (not isinstance(values, list) or not values):
                    self.send_err(400, 1012, "purge values must be a non-empty list")
                    return
                STATE["purges"].append({"scope": scope, "values": values})
                self.send_ok({"id": ZONE_ID})
                return
            if rest == ["dns_records"]:
                for field in ("type", "name", "content", "ttl"):
                    if field not in body:
                        self.send_err(400, 9100, f"missing {field}")
                        return
                record = {"id": NEW_RECORD, "proxied": False} | body
                STATE["dns_records"].append(record)
                self.send_ok(record)
                return
            if rest == ["firewall", "access_rules", "rules"]:
                if "mode" not in body or "configuration" not in body:
                    self.send_err(400, 9100, "missing mode/configuration")
                    return
                rule = {"id": NEW_ACCESS_RULE, "created_on": "2026-08-11T10:00:00Z"} | body
                STATE["access_rules"].append(rule)
                self.send_ok(rule)
                return
            if rest == ["workers", "routes"]:
                if "pattern" not in body:
                    self.send_err(400, 9100, "missing pattern")
                    return
                route = {"id": NEW_ROUTE, "pattern": body["pattern"], "script": body.get("script")}
                STATE["worker_routes"].append(route)
                STATE["events"].append(f'created_route:{body["pattern"]}={body.get("script") or "none"}')
                self.send_ok(route)
                return

        if parts[0] == "accounts" and len(parts) >= 4 and parts[1] == ACCOUNT_ID and parts[2] == "pages" and parts[3] == "projects":
            rest = parts[4:]
            if rest[:1] == [PAGES_PROJECT]:
                deployment_ids = {item["id"] for item in PAGES_DEPLOYMENTS}
                if rest[1:] == ["purge_build_cache"]:
                    STATE["events"].append(f"pages_cache_purge:{PAGES_PROJECT}")
                    self.send_ok(None)
                    return
                if len(rest) == 4 and rest[1] == "deployments" and rest[2] in deployment_ids:
                    deployment = next(item for item in PAGES_DEPLOYMENTS if item["id"] == rest[2])
                    if rest[3] == "rollback":
                        STATE["events"].append(f"pages_rollback:{rest[2]}")
                        self.send_ok(deployment)
                        return
                    if rest[3] == "retry":
                        STATE["events"].append(f"pages_retry:{rest[2]}")
                        retried = dict(deployment)
                        retried["latest_stage"] = {"name": "queued", "status": "active"}
                        self.send_ok(retried)
                        return

        self.send_err(404, 7000, "No route for that URI")

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if not self.authorized():
            return

        parts = path.removeprefix("/client/v4/").split("/")
        if parts[0] == "zones" and len(parts) == 5 and parts[2] == "workers" and parts[3] == "routes":
            if not self.zone_guard(parts[1]):
                return
            body = self.read_json()
            for route in STATE["worker_routes"]:
                if route["id"] == parts[4]:
                    route["pattern"] = body.get("pattern", route["pattern"])
                    route["script"] = body.get("script")
                    STATE["events"].append(f'updated_route:{parts[4]}={route["script"] or "none"}')
                    self.send_ok(route)
                    return
            self.send_err(404, 10009, "Route not found")
            return

        self.send_err(404, 7000, "No route for that URI")

    def do_PATCH(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if not self.authorized():
            return

        parts = path.removeprefix("/client/v4/").split("/")
        body = self.read_json()

        if parts[0] == "zones" and len(parts) >= 2:
            zone_id = parts[1]
            if not self.zone_guard(zone_id):
                return
            rest = parts[2:]
            if not rest:
                if "paused" not in body or not isinstance(body["paused"], bool):
                    self.send_err(400, 9100, "expected a boolean paused field")
                    return
                STATE["zone"]["paused"] = body["paused"]
                STATE["events"].append(f'paused:{str(body["paused"]).lower()}')
                self.send_ok(STATE["zone"])
                return
            if len(rest) == 2 and rest[0] == "settings":
                setting = rest[1]
                if setting not in STATE["settings"]:
                    self.send_err(404, 1006, "unknown setting")
                    return
                if "value" not in body:
                    self.send_err(400, 9100, "missing value")
                    return
                STATE["settings"][setting] = body["value"]
                STATE["events"].append(f'setting:{setting}={body["value"]}')
                result = {"id": setting, "value": body["value"], "editable": True, "modified_on": "2026-08-11T10:00:00Z"}
                if setting == "development_mode" and body["value"] == "on":
                    result["time_remaining"] = 10800
                self.send_ok(result)
                return
            if len(rest) == 2 and rest[0] == "dns_records":
                for record in STATE["dns_records"]:
                    if record["id"] == rest[1]:
                        record.update(body)
                        self.send_ok(record)
                        return
                self.send_err(404, 81044, "Record not found")
                return

        if parts[0] == "accounts" and len(parts) == 4 and parts[1] == ACCOUNT_ID and parts[2:3] == ["load_balancers"]:
            self.send_err(404, 7000, "No route for that URI")
            return
        if parts[0] == "accounts" and len(parts) == 5 and parts[1] == ACCOUNT_ID and parts[2] == "load_balancers" and parts[3] == "pools":
            if parts[4] != POOL_ID:
                self.send_err(404, 1002, "Pool not found")
                return
            if "enabled" in body:
                STATE["pool"]["enabled"] = body["enabled"]
                STATE["events"].append(f'pool_enabled:{str(body["enabled"]).lower()}')
            self.send_ok(STATE["pool"])
            return

        self.send_err(404, 7000, "No route for that URI")

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if not self.authorized():
            return

        parts = path.removeprefix("/client/v4/").split("/")
        if parts[0] == "zones" and len(parts) >= 3:
            zone_id = parts[1]
            if not self.zone_guard(zone_id):
                return
            rest = parts[2:]
            if len(rest) == 2 and rest[0] == "dns_records":
                for record in STATE["dns_records"]:
                    if record["id"] == rest[1]:
                        STATE["dns_records"].remove(record)
                        STATE["events"].append(f"deleted_record:{rest[1]}")
                        self.send_ok({"id": rest[1]})
                        return
                self.send_err(404, 81044, "Record not found")
                return
            if len(rest) == 4 and rest[:3] == ["firewall", "access_rules", "rules"]:
                for rule in STATE["access_rules"]:
                    if rule["id"] == rest[3]:
                        STATE["access_rules"].remove(rule)
                        STATE["events"].append(f"deleted_access_rule:{rest[3]}")
                        self.send_ok({"id": rest[3]})
                        return
                self.send_err(404, 10001, "Access rule not found")
                return
            if len(rest) == 3 and rest[:2] == ["workers", "routes"]:
                for route in STATE["worker_routes"]:
                    if route["id"] == rest[2]:
                        STATE["worker_routes"].remove(route)
                        STATE["events"].append(f"deleted_route:{rest[2]}")
                        self.send_ok({"id": rest[2]})
                        return
                self.send_err(404, 10009, "Route not found")
                return

        self.send_err(404, 7000, "No route for that URI")


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
