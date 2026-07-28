import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

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
        "metadata": {"secret": CANARY, "owner": "app"},
        "contexts": {"custom": {"trace": {"value": CANARY}}},
        "mediaLink": f"https://storage.example.test/download?token={CANARY}",
    }


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
        return {"kind": "storage#objects", "items": [object_metadata()]}
    if path.endswith("/b/harness-bucket/o/logs/app.log"):
        return object_metadata()
    if path.endswith("/b/harness-bucket"):
        return bucket()
    return {"error": {"code": 404, "message": f"unhandled path {raw_path}"}}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = response(self.path)
        status = 404 if "error" in payload else 200
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
