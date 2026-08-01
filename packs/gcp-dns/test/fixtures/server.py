import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CANARY = "packtest-canary-gcp-dns-secret-b521"

MUTATIONS = []
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
        return 200, {"mutations": MUTATIONS}
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
        result = response(self.command, self.path, body)
        if result is None:
            result = 404, error(404, f"unhandled path {self.path}")
        status, payload = result
        encoded = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
