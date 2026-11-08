"""Disposable storage JSON/media contract; uses actual gcloud and curl clients."""
import copy
import json
import re
import ssl
from urllib.parse import parse_qs, unquote, urlparse

BUCKET = "fixture-dataproc-logs"
GENERATION = "9007199254740993"  # Deliberately above exact IEEE754 integer range.


def prefix(name):
    return "provider-selected/jobs/" + name + "/driveroutput"


def driver_job(name, factory):
    result = factory(name)
    result["driverOutputResourceUri"] = "gs://" + BUCKET + "/" + prefix(name)
    if name == "driver-mismatched-job":
        result["reference"]["jobId"] = "different-job"
    if name == "driver-mismatched-project":
        result["reference"]["projectId"] = "different-project"
    if name == "driver-no-output":
        result.pop("driverOutputResourceUri")
    bad = {
        "driver-uri-http": "https://storage.googleapis.com/" + BUCKET + "/object",
        "driver-uri-query": "gs://" + BUCKET + "/driveroutput?credential=private",
        "driver-uri-percent": "gs://" + BUCKET + "/%2e%2e/driveroutput",
        "driver-uri-glob": "gs://" + BUCKET + "/{a,b}/driveroutput",
        "driver-uri-traversal": "gs://" + BUCKET + "/a/../driveroutput",
        "driver-uri-userinfo": "gs://private@" + BUCKET + "/driveroutput",
    }
    if name in bad:
        result["driverOutputResourceUri"] = bad[name]
    return result


def contents(name):
    if name == "driver-window-footer":
        return {0: b"ValueError: fixture-only failure\n" + b"F" * 8192, 1: b""}
    if name == "driver-window-unicode":
        return {0: "αβγ\nTAIL\n".encode(), 1: b""}
    if name == "driver-window-many":
        return {i: ("part-%d\n" % i).encode() for i in range(10)} | {10: b""}
    if name == "driver-window-leading-missing":
        return {5: b"0123456789", 6: b"abcdefghij", 7: b"KLMNOPQRST", 8: b""}
    if name == "driver-window-long":
        return {0: b"0123456789" * 500, 1: b""}
    if name.startswith("driver-window"):
        return {0: b"0123456789", 1: b"abcdefghij", 2: b"KLMNOPQRST", 3: b""}
    if name in ("driver-budget", "driver-tail"):
        return {i: ("segment-%d\n" % i).encode() for i in range(5)} | {5: b""}
    if name == "driver-cross-chunk":
        return {0: b"one\nValue", 1: b"Error: split\n", 2: b""}
    if name == "driver-numeric-order":
        return {999999999: b"older\n", 1000000000: b"newer\n", 1000000001: b""}
    if name == "driver-empty":
        return {0: b""}
    if name == "driver-gap":
        return {0: b"a\n", 2: b"b\n"}
    if name == "driver-middle-zero":
        return {0: b"a\n", 1: b"", 2: b"b\n"}
    if name == "driver-secret":
        return {0: b"Authorization: Bearer packtest-canary-dataproc-error-bearer-8442\nValueError: fixture-only failure\n", 1: b""}
    if name == "driver-redaction-expansion":
        return {0: b"pwd=x " * 682 + b" " * 4, 1: b""}
    if name == "driver-json-secret-expansion":
        return {0: b'"pwd":0,' * 512, 1: b""}
    if name == "driver-worst-json":
        return {0: b'"' * 4096, 1: b""}
    if name == "driver-invalid-utf8":
        return {0: b"\xff" * 4096, 1: b""}
    if name in ("driver-range-ignored", "driver-unknown-overflow"):
        return {0: b"x" * 40000, 1: b""}
    if name == "driver-lines":
        return {0: b"one\ntwo\nthree\n", 1: b""}
    return {0: b"starting\nTraceback (most recent call last):\n", 1: b"ValueError: fixture-only failure\n", 2: b""}


def row(name, index, data):
    return {"name": prefix(name) + ".%09d" % index, "size": str(len(data)),
            "generation": str(int(GENERATION) + index), "contentEncoding": "identity"}


def handle(handler, method, requests):
    u = urlparse(handler.path)
    is_list = u.path == "/storage/v1/b/" + BUCKET + "/o"
    is_media = u.path.startswith("/download/storage/v1/b/" + BUCKET + "/o/")
    if not (is_list or is_media):
        return False
    query = parse_qs(u.query)
    name = query.get("prefix", [""])[0].split("/")[2] if is_list else unquote(u.path.split("/o/", 1)[1]).split("/")[2]
    requests.append({"method": method, "family": "storage_list" if is_list else "storage_media",
                     "target": name, "query": query, "range": handler.headers.get("Range"),
                     "host": handler.headers.get("Host"), "accept_encoding": handler.headers.get("Accept-Encoding")})
    if method != "GET" or handler.headers.get("Host") != "storage.googleapis.com":
        handler.error(400, "Expected fixed-origin GET")
        return True
    data = contents(name)
    if is_list:
        if handler.headers.get("Accept-Encoding") != "identity":
            handler.error(400, "JSON metadata must request identity encoding")
            return True
        expected = {"prefix", "maxResults", "fields"} | ({"pageToken"} if "pageToken" in query else set())
        if set(query) != expected or query.get("prefix") != [prefix(name) + "."] or query.get("maxResults") != ["1000"] or query.get("fields") != ["nextPageToken,items(name,generation,size,contentEncoding)"]:
            handler.error(400, "Unexpected listing selector")
            return True
        rows = sorted([row(name, i, b) for i, b in data.items()], key=lambda item: item["name"])
        page = query.get("pageToken", [""])[0]
        value = {"items": rows}
        if name == "driver-paged" and not page:
            value = {"items": [], "nextPageToken": "next-page"}
        if name == "driver-budget":
            i = int(page or "0")
            value = {"items": rows[i:i + 1] if i < 4 else rows[4:]}
            if i < 4:
                value["nextPageToken"] = str(i + 1)
        if name == "driver-pagination-cap":
            value = {"items": [], "nextPageToken": str(int(page or "0") + 1)}
        if name == "driver-repeated-token":
            value = {"items": [], "nextPageToken": "same-token"}
        if name == "driver-foreign-object":
            value["items"][0]["name"] = "another-job/driveroutput.000000000"
        if name == "driver-invalid-generation":
            value["items"][0]["generation"] = 9007199254740993
        if name == "driver-encoded":
            value["items"][0]["contentEncoding"] = "gzip"
        if name == "driver-oversize-metadata":
            value["padding"] = "x" * 1048577
        handler.send(200, value)
        return True
    object_name = unquote(u.path.split("/o/", 1)[1])
    index = int(object_name.rsplit(".", 1)[1])
    if object_name != prefix(name) + ".%09d" % index or query != {"alt": ["media"], "generation": [str(int(GENERATION) + index)]}:
        handler.error(412, "Expected exact generation-pinned object")
        return True
    if name == "driver-window-precondition":
        handler.error(412, "Pinned generation changed after listing")
        return True
    if name == "driver-gone":
        handler.error(404, "Pinned generation no longer exists")
        return True
    if name in ("driver-416", "driver-window-416"):
        handler.send(416, {"error": {"code": 416}})
        return True
    if name == "driver-redirect":
        handler.send_response(302)
        handler.send_header("Location", "https://forbidden.invalid/private")
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True
    body = data[index]
    header = handler.headers.get("Range", "")
    suffix = re.fullmatch(r"bytes=-([1-9][0-9]*)", header)
    interval = re.fullmatch(r"bytes=(0|[1-9][0-9]*)-(0|[1-9][0-9]*)", header)
    if suffix:
        lower, upper = max(0, len(body) - int(suffix[1])), len(body) - 1
    elif interval:
        lower, upper = int(interval[1]), int(interval[2])
    else:
        handler.error(400, "Expected a bounded single byte range")
        return True
    requested = upper - lower + 1
    if not 0 <= lower <= upper < len(body) or handler.headers.get("Accept-Encoding") != "gzip":
        handler.error(400, "Expected a satisfiable range without decompression")
        return True
    if name == "driver-unknown-overflow":
        handler.protocol_version = "HTTP/1.1"
        handler.send_response(206)
        handler.send_header("Transfer-Encoding", "chunked")
        handler.send_header("Content-Range", "bytes %d-%d/%d" % (len(body) - requested, len(body) - 1, len(body)))
        handler.end_headers()
        try:
            for i in range(0, len(body), 1024):
                chunk = body[i:i + 1024]
                handler.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
            handler.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        return True
    status = 200 if name in ("driver-range-ignored", "driver-whole-200", "driver-window-whole-200", "driver-window-ignored", "driver-window-ignored-subset") else 206
    tail = body if status == 200 and name != "driver-window-ignored-subset" else body[lower:upper + 1]
    handler.send_response(status)
    handler.send_header("Content-Type", "text/plain")
    handler.send_header("Content-Length", str(len(tail)))
    if status == 206:
        handler.send_header("Content-Range", "bytes %d-%d/%d" % (0 if name == "driver-bad-range" else lower + 1 if name == "driver-window-malformed-range" else lower, upper, len(body)))
    if name == "driver-response-encoded":
        handler.send_header("Content-Encoding", "gzip")
    handler.end_headers()
    try:
        handler.wfile.write(tail)
    except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
        pass
    return True
