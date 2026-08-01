import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CANARY = "packtest-canary-gcp-compute-secret-a951"

MUTATIONS = []
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
        return {"mutations": MUTATIONS}
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
        payload = response(self.command, self.path, self.headers.get("Host", "gcp-api:8080"))
        status = 200 if payload is not None else 404
        body = json.dumps(payload or {
            "error": {"code": 404, "message": f"unhandled path {self.path}"}
        }).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = handle_request
    do_POST = handle_request
    do_DELETE = handle_request

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
