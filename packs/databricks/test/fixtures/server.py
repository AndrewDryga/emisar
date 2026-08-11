import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_TOKEN = "packtest-canary-databricks-token-83f2"
# Credential-shaped values the actions must never emit: a JDBC URL on every
# warehouse document and a spark_env_vars secret on the running cluster.
JDBC_SECRET = "packtest-canary-databricks-jdbc-4c7d"
ENV_SECRET = "packtest-canary-databricks-envsecret-1b9e"

WAREHOUSE_ID = "1234567890abcdef"
DEGRADED_WAREHOUSE_ID = "fedcba0987654321"
DASHBOARD_ID = "01f0138fd0d11a23822c3f6384e6c484"
WORST_DASHBOARD_ID = "ffffffffffffffffffffffffffffffff"
ETL_JOB_ID = 947381205673284
ADHOC_JOB_ID = 555777888999000
RUN_OK = 738495610284753
RUN_FAILED = 738495610284777
RUN_ACTIVE = 738495610284800
RUN_LEGACY = 738495610284700
TASK_RUN_OK = 738495610284778
TASK_RUN_FAILED = 738495610284779
TASK_RUN_WORST = 738495610284790
NEW_RUN_ID = 738495610284999
CLUSTER_ID = "0811-104501-ab3cde45"
DEAD_CLUSTER_ID = "0811-090000-de4dbeef"
WORST_CLUSTER_ID = "0811-999999-worst000"
STMT_DONE = "01f01390-0000-1111-9aaa-000000000001"
STMT_RUNNING = "01f01390-0000-1111-9aaa-000000000002"
STMT_FAILED = "01f01390-0000-1111-9aaa-000000000003"
STMT_CLOSED = "01f01390-0000-1111-9aaa-000000000004"

# Every codepoint of this text costs six bytes once JSON-escaped — the single
# most expensive shape a clip can meet — and CONTROL_TEXT spans the full
# Unicode Cc range the cleanup claims (ESC, BEL, NUL, tab, newline, DEL, a C1
# byte), so no escape byte may survive into any projected output.
U2028 = "\u2028"
CONTROL_TEXT = (
    "deploy: \x1b[31m red \x07 bell \x00 null \t tab \n line2 \x7f del \x85 c1 line3"
    + "x" * 80
)
LONG_TOKEN = "t" * 2000


def flood(n):
    return U2028 * n


# ── mutable per-process state (each behavior case owns a fresh server) ──────

WAREHOUSES = {
    WAREHOUSE_ID: {
        "state": "RUNNING",
        "name": "bi-serverless",
        "cluster_size": "Small",
        "min_num_clusters": 1,
        "max_num_clusters": 4,
        "num_clusters": 1,
        "auto_stop_mins": 120,
        "enable_serverless_compute": True,
        "warehouse_type": "PRO",
        "creator_name": "platform@example.test",
        "health": None,
    },
    DEGRADED_WAREHOUSE_ID: {
        "state": "STOPPED",
        "name": "etl-classic",
        "cluster_size": "2X-Small",
        "min_num_clusters": 1,
        "max_num_clusters": 1,
        "num_clusters": 0,
        "auto_stop_mins": 45,
        "enable_serverless_compute": False,
        "warehouse_type": "CLASSIC",
        "creator_name": "data-eng@example.test",
        "health": {
            "status": "DEGRADED",
            "summary": "Cluster acquisition is slow in the current zone",
            "failure_reason": {"code": "CLOUD_PROVIDER_RESOURCE_STOCKOUT", "type": "CLOUD_FAILURE"},
        },
    },
}

CLUSTERS = {
    CLUSTER_ID: {
        "state": "RUNNING",
        "cluster_name": "shared-analytics",
        "state_message": "",
        "spark_version": "15.4.x-scala2.12",
        "node_type_id": "n2-standard-8",
        "driver_node_type_id": "n2-standard-8",
        "autoscale": {"min_workers": 2, "max_workers": 8},
        "num_workers": None,
        "autotermination_minutes": 60,
        "creator_user_name": "platform@example.test",
        "cluster_source": "UI",
        "start_time": 1754815000000,
        "terminated_time": 0,
        "termination_reason": None,
        "spark_env_vars": {"WAREHOUSE_EXPORT_TOKEN": ENV_SECRET},
    },
    DEAD_CLUSTER_ID: {
        "state": "TERMINATED",
        "cluster_name": "nightly-etl-cluster",
        "state_message": "Compute terminated: spot instance reclaimed",
        "spark_version": "15.4.x-scala2.12",
        "node_type_id": "n2-highmem-4",
        "driver_node_type_id": None,
        "autoscale": None,
        "num_workers": 4,
        "autotermination_minutes": 30,
        "creator_user_name": "data-eng@example.test",
        "cluster_source": "JOB",
        "start_time": 1754800000000,
        "terminated_time": 1754812000000,
        "termination_reason": {
            "code": "SPOT_INSTANCE_TERMINATION",
            "type": "CLOUD_FAILURE",
            "parameters": {"instance_id": "i-0abc"},
        },
        "spark_env_vars": {},
    },
}

STATEMENTS = {
    STMT_DONE: "SUCCEEDED",
    STMT_RUNNING: "RUNNING",
    STMT_CLOSED: "CLOSED",
}

RUNS = {
    RUN_OK: {"job_id": ETL_JOB_ID, "state": "TERMINATED", "code": "SUCCESS", "type": "SUCCESS",
             "message": "", "start": 1754820000000, "duration": 421000, "legacy": True},
    RUN_FAILED: {"job_id": ETL_JOB_ID, "state": "TERMINATED", "code": "RUN_EXECUTION_ERROR", "type": "CLIENT_ERROR",
                 "message": "Task transform failed with message: AnalysisException", "start": 1754830000000,
                 "duration": 96000, "legacy": True},
    RUN_ACTIVE: {"job_id": ADHOC_JOB_ID, "state": "RUNNING", "code": None, "type": None,
                 "message": "", "start": 1754840000000, "duration": None, "legacy": False},
    RUN_LEGACY: {"job_id": ETL_JOB_ID, "state": "TERMINATED", "code": "SUCCESS", "type": "SUCCESS",
                 "message": "backfill 2026-08-01", "start": 1754810000000, "duration": 380000,
                 "legacy": True, "legacy_only": True},
}

RUN_NOW_RECORDED = {}
CANCELED_RUNS = set()
LAST_STATEMENT_BODY = {}
OUTPUT_FETCHES = []


# ── document builders ───────────────────────────────────────────────────────

def warehouse_doc(wid):
    w = WAREHOUSES[wid]
    doc = {
        "id": wid,
        "name": w["name"],
        "state": w["state"],
        "cluster_size": w["cluster_size"],
        "min_num_clusters": w["min_num_clusters"],
        "max_num_clusters": w["max_num_clusters"],
        "num_clusters": w["num_clusters"],
        "num_active_sessions": 0,
        "auto_stop_mins": w["auto_stop_mins"],
        "enable_serverless_compute": w["enable_serverless_compute"],
        "warehouse_type": w["warehouse_type"],
        "creator_name": w["creator_name"],
        "jdbc_url": f"jdbc:spark://workspace.example.test:443/default;transportMode=http;pwd={JDBC_SECRET}",
    }
    if w["health"]:
        doc["health"] = w["health"]
    return doc


def worst_warehouse_page():
    return {
        "warehouses": [
            {
                "id": f"{i:016x}",
                "name": flood(70),
                "state": "RUNNING",
                "cluster_size": "4X-Large",
                "num_clusters": 10,
                "auto_stop_mins": 0,
                "enable_serverless_compute": True,
                "warehouse_type": "PRO",
                "health": {"status": "DEGRADED", "summary": flood(200)},
                "jdbc_url": f"jdbc:spark://x/{JDBC_SECRET}",
            }
            for i in range(12)
        ],
        "next_page_token": LONG_TOKEN,
    }


def cluster_doc(cid):
    c = CLUSTERS[cid]
    doc = {
        "cluster_id": cid,
        "cluster_name": c["cluster_name"],
        "state": c["state"],
        "state_message": c["state_message"],
        "spark_version": c["spark_version"],
        "node_type_id": c["node_type_id"],
        "autotermination_minutes": c["autotermination_minutes"],
        "creator_user_name": c["creator_user_name"],
        "cluster_source": c["cluster_source"],
        "start_time": c["start_time"],
        "terminated_time": c["terminated_time"],
        "spark_env_vars": c["spark_env_vars"],
        "spark_context_id": 710439482,
    }
    if c["driver_node_type_id"]:
        doc["driver_node_type_id"] = c["driver_node_type_id"]
    if c["autoscale"]:
        doc["autoscale"] = c["autoscale"]
    if c["num_workers"] is not None:
        doc["num_workers"] = c["num_workers"]
    if c["termination_reason"]:
        doc["termination_reason"] = c["termination_reason"]
    return doc


def worst_cluster_page():
    return {
        "clusters": [
            {
                "cluster_id": f"0811-{i:06d}-worstclu",
                "cluster_name": flood(70),
                "state": "RUNNING",
                "spark_version": CONTROL_TEXT,
                "node_type_id": CONTROL_TEXT,
                "autoscale": {"min_workers": 100, "max_workers": 900},
                "cluster_source": "PIPELINE_MAINTENANCE",
            }
            for i in range(8)
        ],
        "next_page_token": LONG_TOKEN,
    }


def run_doc(rid, with_tasks=False):
    r = RUNS[rid]
    doc = {
        "run_id": rid,
        "job_id": r["job_id"],
        "run_name": "nightly-etl" if r["job_id"] == ETL_JOB_ID else "adhoc-report",
        "start_time": r["start"],
        "end_time": (r["start"] + r["duration"]) if r["duration"] else 0,
        "run_page_url": "https://workspace.example.test/jobs/1/runs/1",
    }
    if r["duration"] is not None:
        doc["run_duration"] = r["duration"]
    if not r.get("legacy_only"):
        status = {"state": r["state"]}
        if r["code"]:
            status["termination_details"] = {"code": r["code"], "type": r["type"], "message": r["message"]}
        doc["status"] = status
    if r.get("legacy"):
        doc["state"] = {
            "life_cycle_state": r["state"],
            "state_message": r["message"],
            **({"result_state": "SUCCESS" if r["code"] == "SUCCESS" else "FAILED"} if r["code"] else {}),
        }
    if with_tasks and rid == RUN_FAILED:
        doc["tasks"] = [
            {
                "task_key": "ingest",
                "run_id": TASK_RUN_OK,
                "status": {"state": "TERMINATED", "termination_details": {"code": "SUCCESS", "type": "SUCCESS", "message": ""}},
                "execution_duration": 30000,
            },
            {
                "task_key": "transform",
                "run_id": TASK_RUN_FAILED,
                "status": {"state": "TERMINATED", "termination_details": {"code": "RUN_EXECUTION_ERROR", "type": "CLIENT_ERROR", "message": "AnalysisException"}},
                "execution_duration": 61000,
            },
        ]
    return doc


def worst_runs_page():
    return {
        "runs": [
            {
                "run_id": 900000000000000 + i,
                "job_id": ETL_JOB_ID,
                "status": {
                    "state": "TERMINATED",
                    "termination_details": {"code": "RUN_EXECUTION_ERROR", "type": "CLIENT_ERROR",
                                            "message": (CONTROL_TEXT if i % 2 else flood(200))},
                },
                "start_time": 1754800000000 + i,
                "run_duration": 1000 * i,
            }
            for i in range(10)
        ],
        "next_page_token": LONG_TOKEN,
    }


def job_doc(job_id):
    if job_id == ETL_JOB_ID:
        return {
            "job_id": ETL_JOB_ID,
            "created_time": 1750000000000,
            "creator_user_name": "data-eng@example.test",
            "run_as_user_name": "svc-jobs@example.test",
            "settings": {
                "name": "nightly-etl",
                "max_concurrent_runs": 1,
                "schedule": {"quartz_cron_expression": "0 0 3 * * ?", "timezone_id": "UTC", "pause_status": "UNPAUSED"},
                "parameters": [
                    {"name": "run_date", "default": ""},
                    {"name": "mode", "default": "full"},
                ],
                "tasks": [
                    {"task_key": "ingest", "notebook_task": {"notebook_path": "/etl/ingest"}},
                    {"task_key": "transform", "spark_python_task": {"python_file": "s3://x/transform.py"},
                     "depends_on": [{"task_key": "ingest"}]},
                    {"task_key": "publish", "sql_task": {"warehouse_id": WAREHOUSE_ID},
                     "depends_on": [{"task_key": "transform"}]},
                ],
            },
        }
    return {
        "job_id": ADHOC_JOB_ID,
        "created_time": 1751000000000,
        "creator_user_name": "analyst@example.test",
        "settings": {"name": "adhoc-report", "tasks": [{"task_key": "report", "notebook_task": {"notebook_path": "/r"}}]},
    }


def worst_jobs_page():
    return {
        "jobs": [
            {
                "job_id": 800000000000000 + i,
                "created_time": 1750000000000,
                "creator_user_name": flood(70),
                "settings": {"name": (CONTROL_TEXT if i % 2 else flood(70))},
            }
            for i in range(10)
        ],
        "next_page_token": LONG_TOKEN,
    }


SERIALIZED_MAIN = json.dumps({
    "datasets": [
        {
            "name": "bf8f76f4",
            "displayName": "Daily matches",
            "queryLines": [
                "SELECT game, count(*) AS matches\n",
                "FROM matches_daily\n",
                "WHERE day >= :param_start\n",
                "GROUP BY 1 ORDER BY 2 DESC",
            ],
            "parameters": [{"displayName": "Start date", "keyword": "param_start",
                            "dataType": "DATE", "defaultSelection": {}}],
            "catalog": "analytics",
            "schema": "gaming",
        },
        {"name": "a1b2c3d4", "displayName": "Legacy dataset", "query": "SELECT 1 AS one"},
    ],
    "pages": [{"name": "2920d0bb", "displayName": "Overview", "pageType": "PAGE_TYPE_CANVAS", "layout": []}],
})

SERIALIZED_WORST = json.dumps({
    "datasets": [
        {
            "name": "huge0000",
            "displayName": "Huge " + flood(60),
            "queryLines": ["SELECT " + flood(400) + "\n"] * 8,
            "parameters": [{"displayName": flood(60), "keyword": "k" * 40} for _ in range(7)],
        }
    ] + [
        {
            "name": f"ds{i:06d}",
            "displayName": flood(60),
            "queryLines": ["SELECT 1"],
            "parameters": [{"displayName": flood(60), "keyword": "k" * 40} for _ in range(7)],
        }
        for i in range(13)
    ],
    "pages": [{"name": f"pg{i:06d}", "displayName": flood(60)} for i in range(9)],
})

DASHBOARDS = {
    DASHBOARD_ID: {
        "dashboard_id": DASHBOARD_ID,
        "display_name": "Game analytics",
        "create_time": "2026-07-01T09:00:00Z",
        "update_time": "2026-08-09T17:30:00Z",
        "lifecycle_state": "ACTIVE",
        "warehouse_id": WAREHOUSE_ID,
        "path": "/Workspace/Dashboards/Game analytics.lvdash.json",
        "serialized_dashboard": SERIALIZED_MAIN,
    },
    WORST_DASHBOARD_ID: {
        "dashboard_id": WORST_DASHBOARD_ID,
        "display_name": flood(70),
        "create_time": "2026-07-02T09:00:00Z",
        "update_time": "2026-08-01T00:00:00Z",
        "lifecycle_state": "ACTIVE",
        "warehouse_id": None,
        "path": "/Workspace/Dashboards/" + ("w" * 200) + ".lvdash.json",
        "serialized_dashboard": SERIALIZED_WORST,
    },
}


def worst_dashboard_page():
    return {
        "dashboards": [
            {
                "dashboard_id": f"{i:032x}",
                "display_name": (CONTROL_TEXT if i % 2 else flood(70)),
                "create_time": "2026-07-01T09:00:00Z",
                "lifecycle_state": "ACTIVE",
                "warehouse_id": WAREHOUSE_ID,
            }
            for i in range(12)
        ],
        "next_page_token": LONG_TOKEN,
    }


def uc_column(name, type_text, type_name, position, comment=None, nullable=True):
    col = {"name": name, "type_text": type_text, "type_name": type_name, "position": position,
           "nullable": nullable}
    if comment:
        col["comment"] = comment
    return col


TABLES = {
    "analytics.gaming.matches_daily": {
        "name": "matches_daily",
        "full_name": "analytics.gaming.matches_daily",
        "table_type": "MANAGED",
        "data_source_format": "DELTA",
        "owner": "data-eng@example.test",
        "comment": "One row per game per day",
        "created_at": 1750000000000,
        "updated_at": 1754900000000,
        "columns": [uc_column("game", "string", "STRING", 0, "game slug"),
                    uc_column("day", "date", "DATE", 1),
                    uc_column("matches", "bigint", "LONG", 2, nullable=False)]
        + [uc_column(f"metric_{i:02d}", "double", "DOUBLE", 3 + i) for i in range(12)],
    },
    "analytics.gaming.kpi_view": {
        "name": "kpi_view",
        "full_name": "analytics.gaming.kpi_view",
        "table_type": "VIEW",
        "owner": "analyst@example.test",
        "comment": "Daily KPI rollup",
        "created_at": 1751000000000,
        "updated_at": 1754000000000,
        "view_definition": "SELECT game, day, matches FROM analytics.gaming.matches_daily WHERE day >= current_date() - 30",
        "columns": [uc_column("game", "string", "STRING", 0), uc_column("day", "date", "DATE", 1),
                    uc_column("matches", "bigint", "LONG", 2)],
    },
    "analytics.gaming.worst_table": {
        "name": "worst_table",
        "full_name": "analytics.gaming.worst_table",
        "table_type": "VIEW",
        "owner": flood(70),
        "comment": flood(200),
        "created_at": 1,
        "updated_at": 2,
        "view_definition": "SELECT " + flood(3000),
        "columns": [uc_column("c" + ("x" * 50) + f"{i:02d}", flood(50), "STRING", i, flood(50))
                    for i in range(40)],
    },
}


def statement_success_doc():
    return {
        "statement_id": STMT_DONE,
        "status": {"state": "SUCCEEDED"},
        "manifest": {
            "format": "JSON_ARRAY",
            "schema": {"column_count": 3, "columns": [
                {"name": "game", "type_text": "STRING", "type_name": "STRING", "position": 0},
                {"name": "matches", "type_text": "BIGINT", "type_name": "LONG", "position": 1},
                {"name": "day", "type_text": "DATE", "type_name": "DATE", "position": 2},
            ]},
            "total_row_count": 3,
            "total_chunk_count": 1,
            "truncated": False,
        },
        "result": {
            "chunk_index": 0,
            "row_count": 3,
            "row_offset": 0,
            "data_array": [
                ["counter_strike_2", "41234", "2026-08-10"],
                ["dota_2", "30122", "2026-08-10"],
                ["valorant", None, "2026-08-10"],
            ],
        },
    }


def statement_worst_doc():
    return {
        "statement_id": STMT_DONE,
        "status": {"state": "SUCCEEDED"},
        "manifest": {
            "schema": {"column_count": 20, "columns": [
                {"name": "c" + ("x" * 38), "type_text": "STRING", "type_name": "STRING", "position": i}
                for i in range(20)
            ]},
            "total_row_count": 500,
            "truncated": True,
        },
        "result": {"data_array": [[flood(200)] * 20 for _ in range(40)]},
    }


def statement_mixed_doc():
    return {
        "statement_id": STMT_DONE,
        "status": {"state": "SUCCEEDED"},
        "manifest": {
            "schema": {"column_count": 3, "columns": [
                {"name": "game", "type_name": "STRING", "position": 0},
                {"name": "matches", "type_name": "LONG", "position": 1},
                {"name": "day", "type_name": "DATE", "position": 2},
            ]},
            "total_row_count": 40,
            "truncated": False,
        },
        "result": {"data_array": [["short", str(i), "2026-08-10"] for i in range(10)]
                   + [[flood(200)] * 3 for _ in range(30)]},
    }


def error_trace_text():
    lines = [f"trace line {i}" for i in range(1, 29)]
    lines.append("\x1b[31mAnalysisException\x1b[0m: Table or view not found: analytics.gaming.raw_events")
    lines.append("\tat org.apache.spark.sql.catalyst.analysis \x07\x00")
    return "\n".join(lines)


# ── HTTP plumbing ───────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_doc(self, status, error_code, message):
        self.send_json({"error_code": error_code, "message": message}, status=status)

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {API_TOKEN}":
            return True
        self.send_error_doc(401, "UNAUTHENTICATED", "Invalid access token.")
        return False

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw or b"{}")

    # ── GET ─────────────────────────────────────────────────────────────────

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path

        if path == "/health":
            self.send_json({"ok": True})
            return
        if path.startswith("/probe/"):
            self.handle_probe(path)
            return
        if not self.authorized():
            return

        if path == "/api/2.0/preview/scim/v2/Me":
            self.send_json({
                "id": "8355995270157029",
                "userName": "svc-emisar@example.test",
                "displayName": "Emisar Service Principal",
                "active": True,
                "emails": [{"value": "svc-emisar@example.test", "primary": True}],
                "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
            })
            return

        if path.startswith("/api/2.0/sql/statements/"):
            statement_id = path.rsplit("/", 1)[1]
            self.handle_statement_get(statement_id)
            return

        if path == "/api/2.0/sql/warehouses":
            if q.get("page_token") == "worst":
                self.send_json(worst_warehouse_page())
            else:
                self.send_json({"warehouses": [warehouse_doc(WAREHOUSE_ID), warehouse_doc(DEGRADED_WAREHOUSE_ID)]})
            return
        if path.startswith("/api/2.0/sql/warehouses/"):
            wid = path.rsplit("/", 1)[1]
            if wid in WAREHOUSES:
                self.send_json(warehouse_doc(wid))
            else:
                self.send_error_doc(404, "RESOURCE_DOES_NOT_EXIST", f"SQL warehouse {wid} does not exist.")
            return

        if path == "/api/2.0/lakeview/dashboards":
            if q.get("page_token") == "worst":
                self.send_json(worst_dashboard_page())
            else:
                listed = [{k: v for k, v in d.items() if k not in ("serialized_dashboard", "update_time", "path")}
                          for d in DASHBOARDS.values()]
                self.send_json({"dashboards": listed})
            return
        if path.startswith("/api/2.0/lakeview/dashboards/"):
            did = path.rsplit("/", 1)[1]
            if did in DASHBOARDS:
                self.send_json(DASHBOARDS[did])
            else:
                self.send_error_doc(404, "RESOURCE_DOES_NOT_EXIST", f"Dashboard {did} does not exist.")
            return

        if path == "/api/2.1/unity-catalog/catalogs":
            self.handle_catalogs(q)
            return
        if path == "/api/2.1/unity-catalog/schemas":
            self.handle_schemas(q)
            return
        if path == "/api/2.1/unity-catalog/tables":
            self.handle_tables(q)
            return
        if path.startswith("/api/2.1/unity-catalog/tables/"):
            full_name = path.rsplit("/", 1)[1]
            if full_name in TABLES:
                self.send_json(TABLES[full_name])
            else:
                self.send_error_doc(404, "RESOURCE_DOES_NOT_EXIST", f"Table {full_name} does not exist.")
            return

        if path == "/api/2.2/jobs/list":
            self.handle_jobs_list(q)
            return
        if path == "/api/2.2/jobs/get":
            job_id = int(q.get("job_id") or 0)
            if job_id in (ETL_JOB_ID, ADHOC_JOB_ID):
                self.send_json(job_doc(job_id))
            else:
                self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Job {job_id} does not exist.")
            return
        if path == "/api/2.2/jobs/runs/list":
            self.handle_runs_list(q)
            return
        if path == "/api/2.2/jobs/runs/get":
            self.handle_run_get(q)
            return
        if path == "/api/2.2/jobs/runs/get-output":
            self.handle_run_output(q)
            return

        if path == "/api/2.1/clusters/list":
            self.handle_clusters_list(q)
            return
        if path == "/api/2.1/clusters/get":
            cid = q.get("cluster_id") or ""
            if cid in CLUSTERS:
                self.send_json(cluster_doc(cid))
            else:
                self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Cluster {cid} does not exist.")
            return

        self.send_error_doc(404, "RESOURCE_DOES_NOT_EXIST", f"No route for {path}")

    # ── POST ────────────────────────────────────────────────────────────────

    def do_POST(self):
        url = urlparse(self.path)
        path = url.path
        if path.startswith("/probe/"):
            self.handle_probe(path)
            return
        if not self.authorized():
            return
        body = self.read_body()

        if path == "/api/2.0/sql/statements":
            self.handle_statement_post(body)
            return
        if path.startswith("/api/2.0/sql/statements/") and path.endswith("/cancel"):
            statement_id = path.rsplit("/", 2)[1]
            if STATEMENTS.get(statement_id) in ("RUNNING", "PENDING"):
                STATEMENTS[statement_id] = "CANCELED"
            self.send_json({})
            return

        if path.startswith("/api/2.0/sql/warehouses/") and path.endswith(("/start", "/stop")):
            wid, verb = path.rsplit("/", 2)[1:]
            if wid not in WAREHOUSES:
                self.send_error_doc(404, "RESOURCE_DOES_NOT_EXIST", f"SQL warehouse {wid} does not exist.")
                return
            state = WAREHOUSES[wid]["state"]
            if verb == "start" and state == "STOPPED":
                WAREHOUSES[wid]["state"] = "STARTING"
            elif verb == "stop" and state in ("RUNNING", "STARTING"):
                WAREHOUSES[wid]["state"] = "STOPPING"
            self.send_json({})
            return

        if path == "/api/2.2/jobs/run-now":
            job_id = body.get("job_id")
            if job_id not in (ETL_JOB_ID, ADHOC_JOB_ID):
                self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Job {job_id} does not exist.")
                return
            RUNS[NEW_RUN_ID] = {"job_id": job_id, "state": "PENDING", "code": None, "type": None,
                                "message": "", "start": 1754850000000, "duration": None, "legacy": False}
            RUN_NOW_RECORDED.update(body)
            self.send_json({"run_id": NEW_RUN_ID, "number_in_job": NEW_RUN_ID})
            return
        if path == "/api/2.2/jobs/runs/cancel":
            run_id = body.get("run_id")
            if run_id not in RUNS:
                self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Run {run_id} does not exist.")
                return
            if RUNS[run_id]["state"] in ("RUNNING", "PENDING", "QUEUED"):
                RUNS[run_id]["state"] = "TERMINATING"
                CANCELED_RUNS.add(run_id)
            self.send_json({})
            return

        if path == "/api/2.1/clusters/events":
            self.handle_cluster_events(body)
            return
        if path in ("/api/2.1/clusters/start", "/api/2.1/clusters/restart"):
            cid = body.get("cluster_id") or ""
            if cid not in CLUSTERS:
                self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Cluster {cid} does not exist.")
                return
            state = CLUSTERS[cid]["state"]
            if path.endswith("/start") and state == "TERMINATED":
                CLUSTERS[cid]["state"] = "PENDING"
                CLUSTERS[cid]["state_message"] = "Finding instances for new nodes"
            elif path.endswith("/restart") and state == "RUNNING":
                CLUSTERS[cid]["state"] = "RESTARTING"
                CLUSTERS[cid]["state_message"] = "Restarting driver"
            self.send_json({})
            return

        self.send_error_doc(404, "RESOURCE_DOES_NOT_EXIST", f"No route for {path}")

    # ── handlers ────────────────────────────────────────────────────────────

    def handle_statement_post(self, body):
        LAST_STATEMENT_BODY.clear()
        LAST_STATEMENT_BODY.update(body)
        statement = body.get("statement") or ""
        if statement == "SELECT worst":
            self.send_json(statement_worst_doc())
        elif statement == "SELECT mixed":
            self.send_json(statement_mixed_doc())
        elif statement == "SELECT pending":
            self.send_json({"statement_id": STMT_RUNNING, "status": {"state": "RUNNING"}})
        elif statement == "SELECT boom":
            self.send_json({
                "statement_id": STMT_FAILED,
                "status": {"state": "FAILED",
                           "error": {"error_code": "BAD_REQUEST",
                                     "message": "[PARSE_SYNTAX_ERROR] Syntax error at or near 'boom'"},
                           "sql_state": "42601"},
            })
        else:
            self.send_json(statement_success_doc())

    def handle_statement_get(self, statement_id):
        state = STATEMENTS.get(statement_id)
        if state is None:
            self.send_error_doc(404, "NOT_FOUND", f"Statement {statement_id} does not exist.")
        elif state == "SUCCEEDED":
            self.send_json(statement_success_doc())
        else:
            self.send_json({"statement_id": statement_id, "status": {"state": state}})

    def handle_catalogs(self, q):
        token = q.get("page_token")
        if token == "worst":
            self.send_json({"catalogs": [
                {"name": flood(70), "catalog_type": "MANAGED_CATALOG", "owner": flood(50),
                 "comment": (CONTROL_TEXT if i % 2 else flood(50)), "created_at": 1750000000000}
                for i in range(10)
            ], "next_page_token": LONG_TOKEN})
        elif token == "uc-page-2":
            self.send_json({"catalogs": [
                {"name": "archive", "catalog_type": "MANAGED_CATALOG", "owner": "platform@example.test",
                 "comment": "Cold storage", "created_at": 1740000000000}
            ]})
        else:
            self.send_json({"catalogs": [
                {"name": "analytics", "catalog_type": "MANAGED_CATALOG", "owner": "platform@example.test",
                 "comment": "Product analytics lakehouse", "created_at": 1748000000000},
                {"name": "system", "catalog_type": "SYSTEM_CATALOG", "owner": "System user",
                 "comment": "", "created_at": 1748000000000},
            ], "next_page_token": "uc-page-2"})

    def handle_schemas(self, q):
        if not q.get("catalog_name"):
            self.send_error_doc(400, "INVALID_PARAMETER_VALUE", "catalog_name is required.")
            return
        if q.get("page_token") == "worst":
            self.send_json({"schemas": [
                {"name": flood(70), "owner": flood(50), "comment": CONTROL_TEXT, "created_at": 1}
                for _ in range(10)
            ], "next_page_token": LONG_TOKEN})
            return
        if q["catalog_name"] != "analytics":
            self.send_json({"schemas": []})
            return
        self.send_json({"schemas": [
            {"name": "gaming", "owner": "data-eng@example.test", "comment": "Game telemetry marts",
             "created_at": 1748100000000},
            {"name": "finance", "owner": "finance-eng@example.test", "comment": "",
             "created_at": 1748200000000},
        ]})

    def handle_tables(self, q):
        if not q.get("catalog_name") or not q.get("schema_name"):
            self.send_error_doc(400, "INVALID_PARAMETER_VALUE", "catalog_name and schema_name are required.")
            return
        if q.get("page_token") == "worst":
            self.send_json({"tables": [
                {"name": flood(70), "table_type": "MANAGED", "data_source_format": "DELTA",
                 "comment": CONTROL_TEXT, "updated_at": 1}
                for _ in range(10)
            ], "next_page_token": LONG_TOKEN})
            return
        if (q["catalog_name"], q["schema_name"]) != ("analytics", "gaming"):
            self.send_json({"tables": []})
            return
        docs = []
        for doc in TABLES.values():
            if doc["name"] == "worst_table":
                continue
            listed = dict(doc)
            if q.get("omit_columns") == "true":
                listed.pop("columns", None)
            docs.append(listed)
        self.send_json({"tables": docs})

    def handle_jobs_list(self, q):
        if q.get("page_token") == "worst":
            self.send_json(worst_jobs_page())
            return
        jobs = [job_doc(ETL_JOB_ID), job_doc(ADHOC_JOB_ID)]
        name = q.get("name")
        if name:
            jobs = [j for j in jobs if j["settings"]["name"].lower() == name.lower()]
        listed = [{"job_id": j["job_id"], "created_time": j["created_time"],
                   "creator_user_name": j["creator_user_name"],
                   "settings": {"name": j["settings"]["name"]}} for j in jobs]
        self.send_json({"jobs": listed})

    def handle_runs_list(self, q):
        if q.get("page_token") == "worst":
            self.send_json(worst_runs_page())
            return
        order = [RUN_ACTIVE, RUN_FAILED, RUN_OK, RUN_LEGACY]
        runs = [rid for rid in order if rid in RUNS]
        if q.get("job_id"):
            runs = [rid for rid in runs if RUNS[rid]["job_id"] == int(q["job_id"])]
        if q.get("active_only") == "true":
            runs = [rid for rid in runs if RUNS[rid]["state"] in ("RUNNING", "PENDING", "QUEUED", "TERMINATING")]
        if q.get("completed_only") == "true":
            runs = [rid for rid in runs if RUNS[rid]["state"] == "TERMINATED"]
        self.send_json({"runs": [run_doc(rid) for rid in runs]})

    def handle_run_get(self, q):
        run_id = int(q.get("run_id") or 0)
        if run_id not in RUNS:
            self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Run {run_id} does not exist.")
            return
        self.send_json(run_doc(run_id, with_tasks=True))

    def handle_run_output(self, q):
        run_id = int(q.get("run_id") or 0)
        OUTPUT_FETCHES.append(run_id)
        if run_id == TASK_RUN_FAILED:
            self.send_json({
                "error": "AnalysisException: Table or view not found: analytics.gaming.raw_events",
                "error_trace": error_trace_text(),
                "logs": "\n".join(f"log line {i}" for i in range(1, 13)),
                "logs_truncated": True,
                "metadata": {"run_id": run_id, "job_id": ETL_JOB_ID,
                             "status": {"state": "TERMINATED",
                                        "termination_details": {"code": "RUN_EXECUTION_ERROR",
                                                                "type": "CLIENT_ERROR", "message": "AnalysisException"}}},
            })
        elif run_id == TASK_RUN_WORST:
            self.send_json({
                "error": flood(200),
                "error_trace": "\n".join(flood(50) for _ in range(300)),
                "logs": "\n".join(flood(50) for _ in range(40)),
                "logs_truncated": True,
                "notebook_output": {"result": flood(2000), "truncated": True},
                "metadata": {"run_id": run_id, "job_id": ETL_JOB_ID,
                             "status": {"state": "TERMINATED",
                                        "termination_details": {"code": "RUN_EXECUTION_ERROR",
                                                                "type": "CLIENT_ERROR", "message": flood(200)}}},
            })
        elif run_id == TASK_RUN_OK:
            self.send_json({
                "notebook_output": {"result": "ingested 41234 rows", "truncated": False},
                "metadata": {"run_id": run_id, "job_id": ETL_JOB_ID,
                             "status": {"state": "TERMINATED",
                                        "termination_details": {"code": "SUCCESS", "type": "SUCCESS", "message": ""}}},
            })
        elif run_id in RUNS:
            self.send_error_doc(400, "INVALID_PARAMETER_VALUE",
                                "Retrieving the output of runs with multiple tasks is not supported. "
                                "Use the run_id of a task run instead.")
        else:
            self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Run {run_id} does not exist.")

    def handle_clusters_list(self, q):
        if q.get("page_token") == "worst":
            self.send_json(worst_cluster_page())
            return
        docs = [cluster_doc(CLUSTER_ID), cluster_doc(DEAD_CLUSTER_ID)]
        state = q.get("filter_by.cluster_states")
        if state:
            docs = [d for d in docs if d["state"] == state]
        self.send_json({"clusters": docs, "next_page_token": ""})

    def handle_cluster_events(self, body):
        cid = body.get("cluster_id") or ""
        if cid == WORST_CLUSTER_ID:
            self.send_json({"events": [
                {"timestamp": 1754800000000 + i, "type": "AUTOSCALING_STATS_REPORT",
                 "details": {"user": flood(50), "current_num_workers": i, "target_num_workers": i + 1}}
                for i in range(12)
            ], "next_page_token": LONG_TOKEN})
            return
        if cid not in CLUSTERS:
            self.send_error_doc(400, "INVALID_PARAMETER_VALUE", f"Cluster {cid} does not exist.")
            return
        if body.get("page_token") == "ev2":
            self.send_json({"events": [
                {"timestamp": 1754800000000, "type": "CREATING",
                 "details": {"user": "data-eng@example.test", "target_num_workers": 4}},
                {"timestamp": 1754800600000, "type": "RUNNING",
                 "details": {"current_num_workers": 4}},
            ]})
            return
        self.send_json({"events": [
            {"timestamp": 1754812000000, "type": "TERMINATING",
             "details": {"reason": {"code": "SPOT_INSTANCE_TERMINATION", "type": "CLOUD_FAILURE"}}},
            {"timestamp": 1754811000000, "type": "DRIVER_NOT_RESPONDING",
             "details": {"driver_state_message": "Driver is up but is not responsive, likely due to GC."}},
            {"timestamp": 1754805000000, "type": "RESIZING",
             "details": {"user": "data-eng@example.test", "current_num_workers": 4, "target_num_workers": 6}},
            {"timestamp": 1754801000000, "type": "STARTING",
             "details": {"user": "data-eng@example.test"}},
        ], "next_page_token": "ev2"})

    def handle_probe(self, path):
        parts = path.strip("/").split("/")
        if parts[1] == "warehouses" and parts[2] in WAREHOUSES:
            self.send_json({"state": WAREHOUSES[parts[2]]["state"]})
        elif parts[1] == "clusters" and parts[2] in CLUSTERS:
            self.send_json({"state": CLUSTERS[parts[2]]["state"]})
        elif parts[1] == "runs" and int(parts[2]) in RUNS:
            rid = int(parts[2])
            self.send_json({"state": RUNS[rid]["state"], "canceled": rid in CANCELED_RUNS,
                            "run_now": RUN_NOW_RECORDED})
        elif parts[1] == "statements":
            if parts[2] == "last":
                self.send_json(LAST_STATEMENT_BODY)
            else:
                self.send_json({"state": STATEMENTS.get(parts[2])})
        elif parts[1] == "output-fetches":
            self.send_json({"fetched": OUTPUT_FETCHES})
        else:
            self.send_json({"error": "unknown probe"}, status=404)


ThreadingHTTPServer(("", 8080), Handler).serve_forever()
