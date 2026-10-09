import json
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CANARY = "packtest-canary-gcp-dns-secret-b521"

MUTATIONS = []
READ_REQUESTS = []
RECORDS = {
    ("api.example.test.", "A"): {"ttl": 300, "rrdatas": ["203.0.113.30"]},
}


def zone():
    return {
        "name": "harness-zone",
        "dnsName": "example.test.",
        "visibility": "public",
        "nameServers": ["ns-cloud-a1.googledomains.com."],
        "dnssecConfig": {"state": "on"},
        "description": CANARY,
        "labels": {"secret": CANARY},
    }


def rrset(name, rtype):
    record = RECORDS[(name, rtype)]
    return {
        "kind": "dns#resourceRecordSet",
        "name": name,
        "type": rtype,
        "ttl": record["ttl"],
        "rrdatas": record["rrdatas"],
    }


def error(code, message):
    return {"error": {"code": code, "message": message}}


def inventory(path, query, billing_project):
    project = path.split("/projects/", 1)[1].split("/", 1)[0]
    zone_name = path.split("/managedZones/", 1)[1].split("/", 1)[0]
    READ_REQUESTS.append({"project": project, "zone": zone_name, "query": query,
                          "billing_project": billing_project})
    if project == "denied-prod":
        return 403, error(403, "record-set list permission denied")
    if zone_name != "harness-zone":
        return 404, error(404, "managed zone not found")
    if project == "badjson-prod":
        return 200, b'{"rrsets":'
    if project == "multidoc-prod":
        return 200, b'{"rrsets":[]}\n{"rrsets":[]}'
    if project == "errorpage-prod":
        return 200, error(403, "unexpected success error")
    if project == "badarray-prod":
        return 200, {"rrsets": {"name": CANARY}}
    if project == "badttl-prod":
        return 200, {"rrsets": [{"name": "api.example.test.", "type": "A",
                                 "ttl": -1, "rrdatas": ["203.0.113.30"]}]}
    if project == "redirect-prod":
        return 302, {"rrsets": [], "unknown": CANARY}
    if project == "transport-prod":
        return 200, {"rrsets": [], "unknown": CANARY}
    if project == "badtype-prod":
        return 200, {"rrsets": [{"name": "api.example.test.", "type": "A", "ttl": 300,
                                 "rrdatas": [{"metadata": CANARY}]}]}
    if project == "oversize-prod":
        return 200, {"rrsets": [], "unknown": "x" * 4194304}
    if project == "overfull-prod":
        return 200, {"rrsets": [rrset("api.example.test.", "A")] * 3,
                     "nextPageToken": "must-not-skip"}
    if project == "empty-prod":
        return 200, {"rrsets": []}
    if project == "empty-page-prod" and not query.get("pageToken"):
        return 200, {"rrsets": [], "nextPageToken": "empty-page-next"}
    if project == "longcursor-prod":
        return 200, {"rrsets": [], "nextPageToken": "x" * 1025}
    if project == "controlcursor-prod":
        return 200, {"rrsets": [], "nextPageToken": "next\npage"}
    if project == "unicodecursor-prod":
        return 200, {"rrsets": [], "nextPageToken": "𐐨" * 257}
    if project == "maxcursor-prod":
        return 200, {"rrsets": [], "nextPageToken": "𐐨" * 256}
    if project == "badcursor-prod":
        return 200, {"rrsets": [], "nextPageToken": {"value": CANARY}}
    if project == "maximum-prod":
        return 200, {"rrsets": [{
            "name": f"record-{i}.example.test.", "type": "TXT", "ttl": 2147483647,
            "rrdatas": ['"' + "x" * 255 + '" "' + "x" * 255 + '"'] * 4,
            "unknown": CANARY,
        } for i in range(100)]}
    records = [
        rrset("api.example.test.", "A"),
        {"name": "ipv6.example.test.", "type": "AAAA", "ttl": 60,
         "rrdatas": ["2001:db8::30"]},
        {"name": "txt.example.test.", "type": "TXT", "ttl": 120,
         "rrdatas": ['"verification=value"', '"quoted \\"value\\""'],
         "description": CANARY},
        {"name": "policy.example.test.", "type": "A", "ttl": 30,
         "routingPolicy": {"wrr": {"items": [{"weight": 1, "rrdatas": ["203.0.113.40"]}]}},
         "unknown": CANARY},
        {"name": "mail.example.test.", "type": "MX", "ttl": 600,
         "rrdatas": ["10 mail.example.test.", "20 backup.example.test."]},
    ]
    cursor = query.get("pageToken", [""])[0]
    cursor_positions = {"": 0, "dns:2&value=+/\"λ": 2, "dns:4&value=+/\"λ": 4,
                        "empty-page-next": 4}
    if cursor not in cursor_positions:
        return 400, error(400, "invalid continuation")
    size = int(query.get("maxResults", ["100"])[0])
    offset = cursor_positions[cursor]
    payload = {"rrsets": records[offset:offset + size], "unknown": CANARY}
    if offset + size < len(records):
        payload["nextPageToken"] = f'dns:{offset + size}&value=+/"λ'
    return 200, payload


def rrset_collection(method, query, body):
    if method == "GET":
        name = query.get("name", [None])[0]
        rtype = query.get("type", [None])[0]
        return 200, {
            "rrsets": [
                rrset(*key) for key in sorted(RECORDS)
                if (name is None or key[0] == name)
                and (rtype is None or key[1] == rtype)
            ]
        }
    if method == "POST":
        record = json.loads(body)
        key = (record["name"], record["type"])
        if key in RECORDS:
            return 409, error(409, f"resource record set {key[0]} already exists")
        RECORDS[key] = {"ttl": record["ttl"], "rrdatas": record["rrdatas"]}
        MUTATIONS.append(
            f"create:{key[0]}:{key[1]}:{record['ttl']}:{','.join(record['rrdatas'])}"
        )
        return 200, rrset(*key)
    return None


def rrset_item(method, path, body):
    name, _, rtype = path.partition("/rrsets/")[2].partition("/")
    key = (name, rtype)
    if key not in RECORDS:
        return 404, error(404, f"resource record set {name} type {rtype} not found")
    if method == "PATCH":
        record = json.loads(body)
        RECORDS[key] = {"ttl": record["ttl"], "rrdatas": record["rrdatas"]}
        MUTATIONS.append(
            f"patch:{name}:{rtype}:{record['ttl']}:{','.join(record['rrdatas'])}"
        )
        return 200, rrset(*key)
    return None


def change_create(body):
    change = json.loads(body)
    deletions = change.get("deletions", [])
    for deletion in deletions:
        key = (deletion["name"], deletion["type"])
        record = RECORDS.get(key)
        if (
            record is None
            or record["ttl"] != deletion.get("ttl")
            or sorted(record["rrdatas"]) != sorted(deletion.get("rrdatas", []))
        ):
            return 412, error(
                412, "Precondition not met for 'entity.change.deletions[0]'"
            )
    for deletion in deletions:
        key = (deletion["name"], deletion["type"])
        del RECORDS[key]
        MUTATIONS.append(f"delete:{key[0]}:{key[1]}")
    for addition in change.get("additions", []):
        key = (addition["name"], addition["type"])
        RECORDS[key] = {"ttl": addition["ttl"], "rrdatas": addition["rrdatas"]}
        MUTATIONS.append(
            f"create:{key[0]}:{key[1]}:{addition['ttl']}:{','.join(addition['rrdatas'])}"
        )
    change.update({"kind": "dns#change", "id": "1", "status": "done"})
    return 200, change


def response(method, raw_path, body):
    parsed = urlparse(raw_path)
    path = parsed.path
    query = parse_qs(parsed.query, keep_blank_values=True)
    if path == "/health":
        return 200, {"ok": True}
    if path == "/probe/state":
        return 200, {"mutations": MUTATIONS, "requests": READ_REQUESTS}
    if path.endswith("/managedZones/harness-zone/rrsets"):
        return rrset_collection(method, query, body)
    if "/managedZones/harness-zone/rrsets/" in path:
        return rrset_item(method, path, body)
    if path.endswith("/managedZones/harness-zone/changes") and method == "POST":
        return change_create(body)
    if "/managedZones/" in path and "/rrsets" in path:
        zone_name = path.partition("/managedZones/")[2].partition("/")[0]
        return 404, error(404, f"managed zone {zone_name} not found")
    if method != "GET":
        return None
    if "/managedZones/harness-zone" in path:
        return 200, zone()
    if "/managedZones" in path:
        return 200, {"managedZones": [zone()]}
    if "/responsePolicies/harness-response/rules" in path:
        return 200, {
            "responsePolicyRules": [{
                "ruleName": "harness-rule",
                "dnsName": "blocked.example.test.",
                "behavior": "NXDOMAIN",
                "description": CANARY,
            }]
        }
    if "/responsePolicies" in path:
        return 200, {
            "responsePolicies": [{
                "responsePolicyName": "harness-response",
                "networks": [{
                    "networkUrl": "projects/example-prod/global/networks/harness-network"
                }],
                "description": CANARY,
            }]
        }
    if "/policies" in path:
        return 200, {
            "policies": [{
                "name": "harness-policy",
                "enableLogging": True,
                "networks": [{
                    "networkUrl": "projects/example-prod/global/networks/harness-network"
                }],
                "alternativeNameServerConfig": {
                    "targetNameServers": [{
                        "ipv4Address": "10.20.0.53",
                        "forwardingPath": "private",
                    }]
                },
                "description": CANARY,
            }]
        }
    return None


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        if self.server.server_port == 8443 and self.command == "GET" and self.path.split("?", 1)[0].endswith("/rrsets"):
            parsed = urlparse(self.path)
            if self.headers.get("Authorization") != "Bearer packtest-canary-gcp-access-token-27be":
                result = 401, error(401, "authentication required")
            else:
                result = inventory(parsed.path, parse_qs(parsed.query, keep_blank_values=True),
                                   self.headers.get("X-Goog-User-Project"))
        else:
            result = response(self.command, self.path, body)
        if result is None:
            result = 404, error(404, f"unhandled path {self.path}")
        status, payload = result
        encoded = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        truncated = "/projects/transport-prod/" in self.path
        self.send_header("Content-Length", str(len(encoded) + (1 if truncated else 0)))
        if status == 302:
            self.send_header("Location", "https://gcp-api:8443/must-not-follow")
        self.end_headers()
        self.wfile.write(encoded)
        if truncated:
            self.close_connection = True

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request

    def log_message(self, fmt, *args):
        pass


tls = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
tls.socket = context.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=tls.serve_forever, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
