import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ACCESS_TOKEN = "packtest-canary-gcp-billing-access-token-7f3c"
BILLING_ACCOUNT = "billingAccounts/01B678-5ED3E1-AD1F9F"
GIB = 1073741824
STANDARD_TABLE = "gcp_billing_export_v1_01B678_5ED3E1_AD1F9F"
DETAILED_TABLE = "gcp_billing_export_resource_v1_01B678_5ED3E1_AD1F9F"

# Each dataset stands in for one export an account can have turned on: the
# standard table, the detailed table with resource-level rows, and a dataset
# where billing export was never enabled at all.
DATASET_TABLES = {
    "billing_export": (STANDARD_TABLE,),
    "slow_export": (STANDARD_TABLE,),
    "detailed_export": (DETAILED_TABLE,),
    "no_export": (),
}


def table(*columns):
    """Shape rows the way BigQuery jobs.query does: a schema plus f/v cells."""
    names = [name for name, _ in columns]
    values = list(zip(*[cells for _, cells in columns]))
    return {
        "kind": "bigquery#queryResponse",
        "schema": {"fields": [{"name": name, "type": "STRING"} for name in names]},
        "rows": [{"f": [{"v": cell} for cell in row]} for row in values],
        "totalRows": str(len(values)),
        "totalBytesProcessed": "4194304",
        "cacheHit": False,
        "jobComplete": True,
    }


def numeric(sql, cast, floating):
    """A NUMERIC column arrives as a plain decimal; a bare FLOAT64 past 1e7
    arrives with an exponent, which is what the casts in the query avoid."""
    return cast if "AS NUMERIC" in sql else floating


def query_response(sql):
    if "MAX(export_time)" in sql:
        # A bare TIMESTAMP arrives as epoch seconds, so an unformatted query
        # gets that shape back and the case that reads a date fails.
        formatted = "FORMAT_TIMESTAMP" in sql
        return table(
            ("latest_export_time",
             ["2026-08-01T06:00:00Z" if formatted else "1.7858532E9"]),
            ("export_lag_hours", ["3"]),
            ("latest_usage_end_time",
             ["2026-08-01T05:00:00Z" if formatted else "1.7858496E9"]),
            ("earliest_usage_start_time",
             ["2026-07-25T00:00:00Z" if formatted else "1.7852832E9"]),
            ("rows_in_window", ["8241"]),
        )
    if "GROUP BY usage_date" in sql:
        return table(
            ("usage_date", ["2026-07-31", "2026-07-30"]),
            ("gross_cost", ["41.5", "38.0"]),
            ("credits", ["-4.5", "-4.0"]),
            ("net_cost", ["37.0", "34.0"]),
            ("currency", ["USD", "USD"]),
        )
    if "GROUP BY service, sku" in sql:
        return table(
            ("service", ["Compute Engine", "Networking"]),
            ("sku", ["N2 Instance Core running in Americas", "Networking Cloud Cdn Cache Lookups"]),
            ("gross_cost", ["96.0", "48.0"]),
            ("credits", ["-9.5", "0.0"]),
            ("net_cost", ["86.5", "48.0"]),
            ("currency", ["USD", "USD"]),
            ("usage_amount", numeric(sql, ["720", "516694142"], ["720.0", "5.16694142E8"])),
            ("usage_unit", ["hour", "count"]),
        )
    if "GROUP BY project_id" in sql:
        return table(
            ("project_id", ["example-prod", "(unattributed)"]),
            ("project_name", ["Example Production", None]),
            ("gross_cost", ["150.0", "12.0"]),
            ("credits", ["-15.0", "0.0"]),
            ("net_cost", ["135.0", "12.0"]),
            ("currency", ["USD", "USD"]),
        )
    if "GROUP BY service" in sql:
        return table(
            ("service", ["Compute Engine", "Cloud SQL"]),
            ("gross_cost", numeric(sql, ["12436395.069", "70"], ["1.2436395069E7", "70.0"])),
            ("credits", ["-138.008554", "-5.75"]),
            ("net_cost", numeric(sql, ["12298386.515", "64.25"], ["1.2298386515E7", "64.25"])),
            ("currency", ["USD", "USD"]),
        )
    return None


def table_path(path):
    """Split a BigQuery tables.get path, or None for another endpoint."""
    parts = path.strip("/").split("/")
    if len(parts) != 8 or parts[:3] != ["bigquery", "v2", "projects"]:
        return None
    if parts[4] != "datasets" or parts[6] != "tables":
        return None
    return parts[3], parts[5], parts[7]


def billing_response(path):
    if path == "/v1/billingAccounts":
        return {
            "billingAccounts": [{
                "name": BILLING_ACCOUNT,
                "displayName": "Harness Billing Account",
                "open": True,
                "currencyCode": "USD",
                "masterBillingAccount": "",
            }]
        }
    if path == f"/v1/{BILLING_ACCOUNT}/projects":
        return {
            "projectBillingInfo": [{
                "name": "projects/example-prod/billingInfo",
                "projectId": "example-prod",
                "billingAccountName": BILLING_ACCOUNT,
                "billingEnabled": True,
            }]
        }
    if path == f"/v1/{BILLING_ACCOUNT}/budgets":
        return {
            "budgets": [{
                "name": f"{BILLING_ACCOUNT}/budgets/harness-budget",
                "displayName": "Harness monthly budget",
                "amount": {"specifiedAmount": {"currencyCode": "USD", "units": "500"}},
                "thresholdRules": [
                    {"thresholdPercent": 0.5},
                    {"thresholdPercent": 0.9, "spendBasis": "FORECASTED_SPEND"},
                ],
                "budgetFilter": {"projects": ["projects/example-prod"]},
            }]
        }
    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self.write_json(200, {"ok": True})
            return
        if not self.authorized():
            return
        reference = table_path(path)
        if reference is not None:
            self.table_reference(*reference)
            return
        payload = billing_response(path)
        if payload is None:
            self.not_found(path)
            return
        self.write_json(200, payload)

    def do_POST(self):
        path = urlparse(self.path).path
        if not self.authorized():
            return
        if not path.endswith("/queries"):
            self.not_found(path)
            return

        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")

        # Every cost action must cap its own scan; an uncapped query would bill
        # whatever the export happens to hold, so the harness refuses it.
        capped = request.get("maximumBytesBilled")
        if not capped:
            self.error_json(400, "query did not cap maximumBytesBilled")
            return
        if int(capped) < 2 * GIB:
            self.error_json(
                400,
                f"Query exceeded limit for bytes billed: {capped}. "
                f"{2 * GIB} or higher required.",
            )
            return

        sql = request.get("query", "")
        # A dataset named for a slow export stands in for a query that outruns
        # the request timeout and returns no rows.
        if "slow_export" in sql:
            self.write_json(200, {"kind": "bigquery#queryResponse", "jobComplete": False})
            return

        payload = query_response(sql)
        if payload is None:
            self.error_json(400, "unhandled query shape")
            return
        self.write_json(200, payload)

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {ACCESS_TOKEN}":
            return True
        self.error_json(401, "invalid token")
        return False

    def table_reference(self, project, dataset, table):
        if table not in DATASET_TABLES.get(dataset, ()):
            self.error_json(
                404,
                f"Not found: Table {project}:{dataset}.{table} "
                "was not found in location US",
            )
            return
        self.write_json(200, {
            "tableReference": {
                "projectId": project,
                "datasetId": dataset,
                "tableId": table,
            }
        })

    def not_found(self, path):
        self.error_json(404, f"unhandled path {path}")

    def error_json(self, status, message):
        self.write_json(status, {"error": {"code": status, "message": message}})

    def write_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
