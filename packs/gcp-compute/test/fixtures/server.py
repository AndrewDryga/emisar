import json
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CANARY = "packtest-canary-gcp-compute-secret-a951"

MUTATIONS = []
READ_REQUESTS = []
MIG_SIZE = {"value": 1}


def instance():
    return {
        "name": "harness-vm",
        "id": "1001",
        "status": "RUNNING",
        "zone": "zones/us-central1-a",
        "machineType": "zones/us-central1-a/machineTypes/e2-small",
        "creationTimestamp": "2026-07-27T00:00:00.000-06:00",
        "lastStartTimestamp": "2026-07-27T00:01:00.000-06:00",
        "cpuPlatform": "Intel Broadwell",
        "hostname": "harness-vm.example.internal",
        "deletionProtection": True,
        "canIpForward": False,
        "networkInterfaces": [{
            "name": "nic0",
            "network": "global/networks/harness-network",
            "subnetwork": "regions/us-central1/subnetworks/harness-subnet",
            "networkIP": "10.20.0.10",
        }],
        "disks": [{
            "deviceName": "harness-vm",
            "boot": True,
            "mode": "READ_WRITE",
            "source": "zones/us-central1-a/disks/harness-vm",
        }],
        "scheduling": {
            "automaticRestart": True,
            "onHostMaintenance": "MIGRATE",
            "provisioningModel": "STANDARD",
        },
        "serviceAccounts": [{
            "email": "runtime@example-prod.iam.gserviceaccount.com",
            "scopes": ["https://www.googleapis.com/auth/cloud-platform"],
        }],
        "tags": {"items": ["app"], "fingerprint": "tags-fingerprint"},
        "labels": {"cluster": "harness"},
        "metadata": {
            "fingerprint": "metadata-fingerprint",
            "items": [{"key": "startup-script", "value": CANARY}],
        },
        "description": CANARY,
    }


def inventory(path, query, billing_project):
    project = path.split("/projects/", 1)[1].split("/", 1)[0]
    READ_REQUESTS.append({"project": project, "query": query, "billing_project": billing_project})
    if project == "denied-prod":
        return 403, {"error": {"code": 403, "message": "instance list permission denied"}}
    if project == "missing-prod":
        return 404, {"error": {"code": 404, "message": "project not found"}}
    if project == "badjson-prod":
        return 200, b'{"items":'
    if project == "multidoc-prod":
        return 200, b'{"items":{}}\n{"items":{}}'
    if project == "errorpage-prod":
        return 200, {"error": {"code": 403, "message": "unexpected success error"}}
    if project == "badscope-prod":
        return 200, {"items": {"zones/us-central1-a": [CANARY]}}
    if project == "badinstances-prod":
        return 200, {"items": {"zones/us-central1-a": {"instances": {"name": CANARY}}}}
    if project == "redirect-prod":
        return 302, {"items": {}, "unknown": CANARY}
    if project == "transport-prod":
        return 200, {"items": {}, "unknown": CANARY}
    if project == "oversize-prod":
        return 200, {"items": {}, "unknown": "x" * 4194304}
    if project == "partial-prod":
        return 200, {"items": {}, "unreachables": ["zones/us-central1-b"]}
    if project == "warning-prod":
        return 200, {"items": {"zones/us-central1-a": {
            "warning": {"code": "UNREACHABLE", "message": CANARY}}}}
    if project == "empty-prod":
        return 200, {"items": {"zones/us-central1-a": {
            "warning": {"code": "NO_RESULTS_ON_PAGE"}}}}
    if project == "empty-top-prod":
        return 200, {"warning": {"code": "NO_RESULTS_ON_PAGE", "message": CANARY}}
    if project == "warning-top-prod":
        return 200, {"warning": {"code": "UNREACHABLE", "message": CANARY}}
    if project == "empty-top-page-prod" and not query.get("pageToken"):
        return 200, {"warning": {"code": "NO_RESULTS_ON_PAGE"}, "nextPageToken": "empty-page-next"}
    if project == "empty-page-prod" and not query.get("pageToken"):
        return 200, {"items": {}, "nextPageToken": "empty-page-next"}
    if project == "longcursor-prod":
        return 200, {"items": {}, "nextPageToken": "x" * 1025}
    if project == "controlcursor-prod":
        return 200, {"items": {}, "nextPageToken": "next\npage"}
    if project == "unicodecursor-prod":
        return 200, {"items": {}, "nextPageToken": "𐐨" * 257}
    if project == "maxcursor-prod":
        return 200, {"items": {}, "nextPageToken": "𐐨" * 256}
    if project == "badcursor-prod":
        return 200, {"items": {}, "nextPageToken": {"value": CANARY}}
    if project == "maximum-prod":
        labels = {f"label{i:03d}" + "𐐨" * 55: "𐐨" * 63 for i in range(64)}
        return 200, {"items": {"zones/us-central1-a": {"instances": [{
            "name": f"max-vm-{i}", "zone": "zones/us-central1-a", "status": "RUNNING",
            "machineType": "zones/us-central1-a/machineTypes/e2-small",
            "labels": labels, "metadata": {"items": [{"key": "startup-script", "value": CANARY}]},
        } for i in range(100)]}}}
    running = instance()
    running["labels"]["password"] = CANARY
    running["networkInterfaces"][0].update({
        "ipv6AccessType": "EXTERNAL",
        "accessConfigs": [{"natIP": "203.0.113.10", "unknown": CANARY}],
        "ipv6AccessConfigs": [{"externalIpv6": "2001:db8::10"}],
    })
    running["networkInterfaces"].append({
        "name": "nic1", "networkIP": "10.21.0.10",
        "ipv6Address": "fd20::10", "ipv6AccessType": "INTERNAL",
    })
    unmanaged = {"name": "unmanaged-vm", "zone": "zones/us-central1-b", "status": "TERMINATED",
                 "machineType": "zones/us-central1-b/machineTypes/e2-medium", "labels": {"owner": "ops"}}
    records = [running, unmanaged,
               {"name": "third-vm", "zone": "zones/europe-west1-b", "status": "RUNNING",
                "machineType": "zones/europe-west1-b/machineTypes/e2-small"}]
    if project == "badlabels-prod":
        running["labels"] = {"owner": {"value": CANARY}}
    if project == "badnetwork-prod":
        running["networkInterfaces"] = [{"networkIP": {"value": CANARY}}]
    cursor = query.get("pageToken", [""])[0]
    if cursor not in ("", 'compute:2&value=+/"λ', "empty-page-next"):
        return 400, {"error": {"code": 400, "message": "invalid continuation"}}
    size = int(query.get("maxResults", ["100"])[0])
    offset = 2 if cursor else 0
    selected = records[offset:offset + size]
    if project == "overfull-prod":
        selected = records
    items = {"zones/us-east1-c": {"warning": {"code": "NO_RESULTS_ON_PAGE"}}}
    for record in selected:
        items.setdefault(record["zone"], {"instances": []})["instances"].append(record)
    if project == "contradictory-scope-prod":
        items["zones/us-central1-a"]["warning"] = {"code": "NO_RESULTS_ON_PAGE"}
    payload = {"items": items, "unknown": CANARY}
    if project == "contradictory-top-prod":
        payload["warning"] = {"code": "NO_RESULTS_ON_PAGE"}
    if offset + size < len(records) or project == "overfull-prod":
        payload["nextPageToken"] = f'compute:{offset + size}&value=+/"λ'
    return 200, payload


def managed_instances():
    return {
        "managedInstances": [{
            "instance": (
                "https://compute.googleapis.com/compute/v1/projects/example-prod/"
                "zones/us-central1-a/instances/harness-vm"
            ),
            "instanceStatus": "RUNNING",
            "currentAction": "NONE",
            "version": {
                "instanceTemplate": (
                    "global/instanceTemplates/harness-template"
                )
            },
            "lastAttempt": {"errors": {"errors": []}},
        }]
    }


def manager(region=False):
    location = "regions/us-central1" if region else "zones/us-central1-a"
    return {
        "name": "harness-mig",
        "targetSize": MIG_SIZE["value"],
        "status": {
            "isStable": True,
            "versionTarget": {"isReached": True},
            "stateful": {"hasStatefulConfig": False},
        },
        "versions": [{
            "name": "primary",
            "instanceTemplate": "global/instanceTemplates/harness-template",
            "targetSize": {"fixed": 1},
        }],
        "autoHealingPolicies": [{
            "healthCheck": "global/healthChecks/harness-health",
            "initialDelaySec": 60,
        }],
        "updatePolicy": {
            "type": "PROACTIVE",
            "minimalAction": "REPLACE",
            "maxSurge": {"fixed": 1},
        },
        "instanceGroup": f"{location}/instanceGroups/harness-mig",
        "description": CANARY,
    }


def operation(path):
    if "/global/" in path:
        scope = {"targetLink": "global/instanceTemplates/harness-template"}
    elif "/regions/" in path:
        scope = {
            "region": "regions/us-central1",
            "targetLink": "regions/us-central1/addresses/harness-address",
        }
    else:
        scope = {
            "zone": "zones/us-central1-a",
            "targetLink": "zones/us-central1-a/instances/harness-vm",
        }
    return {
        "name": "harness-operation",
        "status": "DONE",
        "operationType": "insert",
        "progress": 100,
        "insertTime": "2026-07-27T00:00:00.000-06:00",
        "startTime": "2026-07-27T00:00:01.000-06:00",
        "endTime": "2026-07-27T00:00:02.000-06:00",
        "warnings": [],
        "clientOperationId": CANARY,
        **scope,
    }


def mutation_operation(kind, path, host):
    # gcloud parses selfLink to build the operation reference, so it must be a
    # real URL under the overridden endpoint's scope path. start/stop run with
    # --async and return a RUNNING operation; reset/delete/resize have no
    # --async flag, so their operation completes immediately for the sync wait.
    scope_path = path.split("/instances/")[0].split("/instanceGroupManagers/")[0]
    running = kind in ("start", "stop")
    if "/regions/" in path:
        scope = {"region": "regions/us-central1"}
    else:
        scope = {"zone": "zones/us-central1-a"}
    target_path = path.removesuffix(f"/{kind}") if path.endswith(f"/{kind}") else path
    return {
        "name": f"harness-operation-{kind}",
        "status": "RUNNING" if running else "DONE",
        "operationType": kind,
        "progress": 0 if running else 100,
        "insertTime": "2026-07-27T00:00:00.000-06:00",
        "selfLink": f"http://{host}{scope_path}/operations/harness-operation-{kind}",
        "targetLink": f"http://{host}{target_path}",
        "clientOperationId": CANARY,
        **scope,
    }


def mutation(method, path, query, host):
    for verb in ("start", "stop", "reset"):
        if method == "POST" and path.endswith(f"/instances/harness-vm/{verb}"):
            MUTATIONS.append(f"{verb}:harness-vm")
            return mutation_operation(verb, path, host)
    if method == "DELETE" and path.endswith("/instances/harness-vm"):
        MUTATIONS.append("delete:harness-vm")
        return mutation_operation("delete", path, host)
    if method == "POST" and path.endswith("/instanceGroupManagers/harness-mig/resize"):
        size = parse_qs(query).get("size", ["missing"])[0]
        MUTATIONS.append(f"resize:harness-mig:{size}")
        if size.isdigit():
            MIG_SIZE["value"] = int(size)
        return mutation_operation("resize", path, host)
    return None


def response(method, raw_path, host):
    parsed = urlparse(raw_path)
    path = parsed.path
    if path == "/health":
        return {"ok": True}
    if path == "/probe/state":
        return {"mutations": MUTATIONS, "requests": READ_REQUESTS}
    mutated = mutation(method, path, parsed.query, host)
    if mutated is not None:
        return mutated
    if method == "GET" and path.endswith("/instances/harness-vm"):
        return instance()
    if path.endswith("/instances/harness-vm/serialPort"):
        return {
            "contents": "harness boot complete\n",
            "next": "22",
            "selfLink": path,
        }
    if path.endswith("/instanceGroupManagers/harness-mig/listManagedInstances"):
        if method != "POST":
            return None
        return managed_instances()
    if path.endswith("/instanceGroupManagers/harness-mig"):
        return manager(region="/regions/" in path)
    if path.endswith("/operations/harness-operation"):
        return operation(path)
    return None


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        parsed = urlparse(self.path)
        if self.server.server_port == 8443 and self.command == "GET" and parsed.path.endswith("/aggregated/instances"):
            if self.headers.get("Authorization") != "Bearer packtest-canary-gcp-compute-access-token-011a":
                status, payload = 401, {"error": {"code": 401, "message": "authentication required"}}
            else:
                status, payload = inventory(parsed.path, parse_qs(parsed.query, keep_blank_values=True),
                                            self.headers.get("X-Goog-User-Project"))
        else:
            payload = response(self.command, self.path, self.headers.get("Host", "gcp-api:8080"))
            status = 200 if payload is not None else 404
        payload = payload if payload is not None else {
            "error": {"code": 404, "message": f"unhandled path {self.path}"}}
        body = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        truncated = "/projects/transport-prod/" in self.path
        self.send_header("Content-Length", str(len(body) + (1 if truncated else 0)))
        if status == 302:
            self.send_header("Location", "https://gcp-api:8443/must-not-follow")
        self.end_headers()
        self.wfile.write(body)
        if truncated:
            self.close_connection = True

    do_GET = handle_request
    do_POST = handle_request
    do_DELETE = handle_request

    def log_message(self, fmt, *args):
        pass


tls = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
tls.socket = context.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=tls.serve_forever, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
