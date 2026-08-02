import json
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CANARY = "packtest-canary-gcp-sql-secret-da31"

MUTATIONS = []

# Query Insights is read from Cloud Monitoring rather than the SQL Admin API,
# and that read enforces HTTPS, so the fixture serves TLS on a second port.
def time_series(reducer):
    def series(query_hash, querystring, total):
        # REDUCE_PERCENTILE_* returns a double; the summing reducers keep INT64.
        value = ({"doubleValue": total / 4} if reducer.startswith("REDUCE_PERCENTILE")
                 else {"int64Value": str(total)})
        return {
            "metric": {"labels": {"query_hash": query_hash, "querystring": querystring}},
            "resource": {"type": "cloudsql_instance_database"},
            "points": [{"value": value}],
        }

    return {
        "timeSeries": [
            series("8811", 'SELECT count(o0."id") FROM "orders" AS o0 WHERE (o0."state" = $1)', 9000000),
            series("2277", 'UPDATE "sessions" AS s0 SET "seen_at" = $1', 3000000),
            series("5533", 'SELECT $1', 1500000),
        ]
    }


def instance():
    return {
        "name": "harness-sql",
        "project": "example-prod",
        "region": "us-central1",
        "gceZone": "us-central1-a",
        "secondaryGceZone": "us-central1-b",
        "databaseVersion": "POSTGRES_16",
        "state": "RUNNABLE",
        "instanceType": "CLOUD_SQL_INSTANCE",
        "connectionName": "example-prod:us-central1:harness-sql",
        "ipAddresses": [{"type": "PRIVATE", "ipAddress": "10.20.0.40"}],
        "settings": {
            "tier": "db-custom-2-8192",
            "edition": "ENTERPRISE",
            "availabilityType": "REGIONAL",
            "dataDiskType": "PD_SSD",
            "dataDiskSizeGb": "100",
            "storageAutoResize": True,
            "backupConfiguration": {
                "enabled": True,
                "pointInTimeRecoveryEnabled": True,
                "transactionLogRetentionDays": 7,
                "startTime": "03:00",
            },
            "ipConfiguration": {
                "ipv4Enabled": False,
                "privateNetwork": "projects/example-prod/global/networks/harness-network",
                "sslMode": "TRUSTED_CLIENT_CERTIFICATE_REQUIRED",
            },
            "databaseFlags": [
                {"name": "cloudsql.iam_authentication", "value": CANARY}
            ],
            "userLabels": {"secret": CANARY},
        },
        "rootPassword": CANARY,
        "replicaConfiguration": {
            "mysqlReplicaConfiguration": {"password": CANARY}
        },
    }


def operation():
    return {
        "name": "harness-operation",
        "operationType": "UPDATE",
        "status": "DONE",
        "targetId": "harness-sql",
        "targetProject": "example-prod",
        "user": "operator@example.test",
        "insertTime": "2026-07-27T00:00:00Z",
        "startTime": "2026-07-27T00:00:01Z",
        "endTime": "2026-07-27T00:00:02Z",
        "importContext": {"uri": f"gs://bucket/{CANARY}"},
    }


def mutation_operation(kind):
    return {
        "name": f"harness-{kind.lower()}-operation",
        "operationType": kind,
        "status": "PENDING",
        "targetId": "harness-sql",
        "targetProject": "example-prod",
        "user": "operator@example.test",
        "insertTime": "2026-07-27T00:00:00Z",
        "importContext": {"uri": f"gs://bucket/{CANARY}"},
    }


def mutate(path):
    if "/instances/harness-sql/restart" in path:
        MUTATIONS.append("restart:harness-sql")
        return mutation_operation("RESTART")
    if "/instances/harness-sql/failover" in path:
        MUTATIONS.append("failover:harness-sql")
        return mutation_operation("FAILOVER")
    return {"error": {"code": 404, "message": f"unhandled path {path}"}}


def response(path):
    if path == "/health":
        return {"ok": True}
    if path == "/probe/state":
        return {"mutations": MUTATIONS}
    if "/instances/harness-sql/databases" in path:
        return {
            "items": [{
                "name": "harness_db",
                "instance": "harness-sql",
                "project": "example-prod",
                "charset": "UTF8",
                "collation": "en_US.UTF8",
            }]
        }
    if "/instances/harness-sql/users" in path:
        return {
            "items": [{
                "name": "harness_user",
                "host": "%",
                "instance": "harness-sql",
                "project": "example-prod",
                "type": "BUILT_IN",
                "password": CANARY,
                "passwordPolicy": {"status": {"locked": False}},
            }]
        }
    if "/instances/harness-sql/backupRuns" in path:
        return {
            "items": [{
                "id": "1001",
                "instance": "harness-sql",
                "project": "example-prod",
                "status": "SUCCESSFUL",
                "type": "AUTOMATED",
                "backupKind": "SNAPSHOT",
                "databaseVersion": "POSTGRES_16",
                "location": "us",
                "windowStartTime": "2026-07-27T03:00:00Z",
                "description": CANARY,
            }]
        }
    if "/instances/harness-sql/listServerCas" in path:
        return {
            "activeVersion": "AB:CD:EF",
            "certs": [{
                "certSerialNumber": "100",
                "commonName": "harness-server-ca",
                "createTime": "2026-07-27T00:00:00Z",
                "expirationTime": "2027-07-27T00:00:00Z",
                "instance": "harness-sql",
                "sha1Fingerprint": "AB:CD:EF",
                "type": "GOOGLE_MANAGED_INTERNAL_CA",
                "cert": f"-----BEGIN CERTIFICATE-----{CANARY}",
            }],
        }
    if "/instances/harness-sql" in path:
        return instance()
    if "/operations/harness-restart-operation" in path:
        return mutation_operation("RESTART")
    if "/operations/harness-failover-operation" in path:
        return mutation_operation("FAILOVER")
    if "/operations/harness-operation" in path:
        return operation()
    if "/operations" in path:
        return {"items": [operation()]}
    if path.split("?", 1)[0].rstrip("/").endswith("/instances"):
        return {"items": [instance()]}
    return {"error": {"code": 404, "message": f"unhandled path {path}"}}


def monitoring(path):
    query = parse_qs(urlparse(path).query, keep_blank_values=True)
    filter_value = query.get("filter", [""])[0]
    # The ranking is only well defined when every series collapses to one point,
    # so the fixture refuses a request that forgot to align over the window.
    if not query.get("aggregation.alignmentPeriod", [""])[0]:
        return {"error": {"code": 400, "message": "aggregation.alignmentPeriod is required"}}
    if "insights/perquery/" not in filter_value:
        return {"error": {"code": 400, "message": f"unhandled filter {filter_value}"}}
    if "no-such-instance" in filter_value:
        return {"timeSeries": []}
    reducer = query.get("aggregation.crossSeriesReducer", [""])[0]
    return time_series(reducer)


class Handler(BaseHTTPRequestHandler):
    def reply(self, payload):
        status = payload["error"].get("code", 404) if "error" in payload else 200
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if "/v3/projects/" in self.path:
            self.reply(monitoring(self.path))
            return
        self.reply(response(self.path))

    def do_POST(self):
        self.reply(mutate(self.path))

    def log_message(self, fmt, *args):
        pass


tls = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
tls.socket = context.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=tls.serve_forever, daemon=True).start()

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
