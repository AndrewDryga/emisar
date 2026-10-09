import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

CANARY = "packtest-canary-gcp-storage-secret-e939"


def bucket():
    return {
        "name": "harness-bucket",
        "location": "US",
        "locationType": "multi-region",
        "storageClass": "STANDARD",
        "rpo": "DEFAULT",
        "iamConfiguration": {
            "uniformBucketLevelAccess": {"enabled": True},
            "publicAccessPrevention": "enforced",
        },
        "versioning": {"enabled": True},
        "retentionPolicy": {
            "retentionPeriod": "604800",
            "isLocked": False,
            "effectiveTime": "2026-07-01T00:00:00Z",
        },
        "lifecycle": {
            "rule": [{
                "action": {"type": "SetStorageClass", "storageClass": "NEARLINE"},
                "condition": {"age": 30},
            }]
        },
        "encryption": {
            "defaultKmsKeyName": (
                "projects/example-prod/locations/us/keyRings/app/cryptoKeys/storage"
            )
        },
        "softDeletePolicy": {"retentionDurationSeconds": "604800"},
        "labels": {"secret": CANARY},
    }


def object_metadata():
    return {
        "name": "logs/app.log",
        "bucket": "harness-bucket",
        "size": "4096",
        "contentType": "text/plain",
        "storageClass": "STANDARD",
        "generation": "1721000000000000",
        "metageneration": "1",
        "timeCreated": "2026-07-01T00:00:00Z",
        "updated": "2026-07-01T00:01:00Z",
        "md5Hash": "CY9rzUYh03PK3k6DJie09g==",
        "crc32c": "ImIEBA==",
        "etag": "CKCnk9qXxocDEAE=",
        "retention": {
            "mode": "Unlocked",
            "retainUntilTime": "2027-07-01T00:00:00Z",
        },
        "metadata": {"secret": CANARY, "owner": "app"},
        "contexts": {"custom": {"trace": {"value": CANARY}}},
        "mediaLink": f"https://storage.example.test/download?token={CANARY}",
    }


def object_list(query):
    prefix = query.get("prefix", [""])[0]
    page_token = query.get("pageToken", [""])[0]
    # Apitools encodes Boolean query values as Python's True/False strings.
    versions = query.get("versions", ["false"])[0].lower() == "true"
    live = object_metadata()
    old = dict(live, generation="1720000000000000",
               timeDeleted="2026-07-01T00:01:00Z")
    if prefix.startswith("denied/"):
        return {"error": {"code": 403, "message": "fixture list permission denied"}}
    if prefix.startswith("page-denied/"):
        if page_token:
            return {"error": {"code": 403, "message": "fixture second page denied"}}
        old["name"] = "page-denied/app.log"
        live["name"] = old["name"]
        rows = [old, live] if versions else [live]
    elif prefix.startswith("old-only/"):
        old["name"] = "old-only/app.log"
        rows = [old] if versions else []
    elif live["name"].startswith(prefix):
        rows = [old, live] if versions else [live]
    else:
        rows = []
    # This is API pagination, not gcloud's local filter or returned-row limit.
    if page_token not in ("", "live-generation"):
        return {"error": {"code": 400, "message": "invalid fixture page token"}}
    if page_token == "live-generation":
        rows = rows[1:]
    result = {"kind": "storage#objects", "items": rows[:1]}
    if len(rows) > 1:
        result["nextPageToken"] = "live-generation"
    return result


def response(raw_path):
    split = urlsplit(raw_path)
    path = unquote(split.path)
    if path == "/health":
        return {"ok": True}
    if path.rstrip("/") == "/storage/v1/b":
        return {"kind": "storage#buckets", "items": [bucket()]}
    if path.endswith("/b/harness-bucket/iam"):
        return {
            "version": 3,
            "etag": "BwWWja0YfJA=",
            "bindings": [{
                "role": "roles/storage.objectViewer",
                "members": ["group:readers@example.test"],
            }],
        }
    if path.endswith("/b/harness-bucket/o"):
        return object_list(parse_qs(split.query))
    if path.endswith("/b/harness-bucket/o/logs/app.log"):
        return object_metadata()
    if path.endswith("/b/harness-bucket"):
        return bucket()
    return {"error": {"code": 404, "message": f"unhandled path {raw_path}"}}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = response(self.path)
        status = payload.get("error", {}).get("code", 200)
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
