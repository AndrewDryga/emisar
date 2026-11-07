#!/bin/bash
set -euo pipefail
# All executable bytes are in this declared, signed script. Isolated Python
# supplies exact int64 parsing and independently bounded real-client pipes.
exec python3 -I - "$@" <<'PY'
"""Read only the current Dataproc Job's provider-selected driver output."""
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from urllib.parse import quote, urlencode

DEADLINE = time.monotonic() + 75
METADATA_CAP = 1048576
HEADER_CAP = 16384
# Shipped redaction can grow a one-byte assignment value to [REDACTED].
# Reserve headroom for its decoded string and JSON/schema representation.
EMITTED_TEXT_CAP = 1024
I64 = 9223372036854775807
SAFE_ENV = {k: v for k, v in os.environ.items() if k in {
    "PATH", "HOME", "LANG", "LC_ALL", "TZ", "TMPDIR", "CLOUDSDK_CONFIG",
    "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "CLOUDSDK_AUTH_ACCESS_TOKEN",
    "CLOUDSDK_CORE_ACCOUNT", "CLOUDSDK_CORE_PROJECT", "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE",
    "CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"}}


class Failure(Exception):
    pass


ACTIVE_CHILD = None


def cancel(_signal, _frame):
    if ACTIVE_CHILD is not None:
        try:
            os.killpg(ACTIVE_CHILD.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    raise Failure("Driver-log read was cancelled.")


signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)


def remaining():
    value = DEADLINE - time.monotonic()
    if value <= 0:
        raise Failure("Driver log read exceeded its 75-second deadline.")
    return value


def child(argv, data=b"", cap=8192, seconds=20, http_cap=None):
    """Bound both pipes independently, including headers and unknown lengths."""
    global ACTIVE_CHILD
    end = min(DEADLINE, time.monotonic() + seconds)
    remaining()
    try:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env={k: v for k, v in SAFE_ENV.items() if argv[0] != "curl" or not k.startswith("CLOUDSDK_")}, start_new_session=True)
    except OSError:
        raise Failure("A required driver-log client could not start.") from None
    ACTIVE_CHILD = process
    selector = selectors.DefaultSelector()
    output = bytearray()
    diagnostic = bytearray()
    completed = False
    body_offset = None
    header_start = 0
    try:
        process.stdin.write(data)
        process.stdin.close()
        for pipe, target, limit in [(process.stdout, output, cap), (process.stderr, diagnostic, 4096)]:
            selector.register(pipe, selectors.EVENT_READ, (target, limit))
        while selector.get_map():
            wait = end - time.monotonic()
            if wait <= 0:
                raise Failure("Driver-log client exceeded its bounded deadline.")
            for key, _ in selector.select(min(wait, 0.25)):
                target, limit = key.data
                read_limit = min(8192, limit + 1 - len(target))
                if target is output and http_cap is not None:
                    # Read headers bytewise so a short body budget cannot hide
                    # extra log bytes inside an unused header allowance.
                    read_limit = 1 if body_offset is None else min(read_limit, http_cap + 1 - (len(output) - body_offset))
                block = os.read(key.fileobj.fileno(), read_limit)
                if not block:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                else:
                    target.extend(block)
                    if target is output and http_cap is not None:
                        if body_offset is None:
                            if len(output) > HEADER_CAP:
                                raise Failure("Google API response exceeded its header byte limit.")
                            if output.endswith(b"\r\n\r\n"):
                                status_line = bytes(output[header_start:]).split(b"\r\n", 1)[0]
                                match = re.fullmatch(rb"HTTP/[0-9.]+ ([0-9]{3})(?: [^\r\n]*)?", status_line)
                                if not match:
                                    raise Failure("Google API response has an invalid HTTP status.")
                                if 100 <= int(match[1]) < 200:
                                    header_start = len(output)
                                else:
                                    body_offset = len(output)
                        elif len(output) - body_offset > http_cap:
                            raise Failure("Google API response exceeded its body byte limit.")
                    if len(target) > limit:
                        raise Failure("Driver-log client response exceeded its byte limit.")
        wait = min(end - time.monotonic(), remaining())
        if wait <= 0:
            raise Failure("Driver-log client exceeded its bounded deadline.")
        code = process.wait(timeout=wait)
        completed = True
        return code, bytes(output)
    except (BrokenPipeError, subprocess.TimeoutExpired):
        raise Failure("Driver-log client failed or exceeded its deadline.") from None
    finally:
        selector.close()
        if not completed:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for pipe in (process.stdin, process.stdout, process.stderr):
            pipe.close()
        try:
            process.wait(timeout=max(0.01, min(1, DEADLINE - time.monotonic())))
        except subprocess.TimeoutExpired:
            raise Failure("Driver-log client could not be reaped within its deadline.") from None
        finally:
            ACTIVE_CHILD = None


def decode(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise Failure("Google API JSON contains duplicate fields.")
            value[key] = item
        return value
    def invalid(_):
        raise Failure("Google API JSON contains an invalid number.")
    try:
        value = json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)
    except (ValueError, UnicodeError, RecursionError):
        raise Failure("Google API response is not valid bounded JSON.") from None
    if type(value) is not dict:
        raise Failure("Google API response must be a JSON object.")
    return value


def http(url, access, cap, extra=(), media=False):
    # The bearer is supplied only over a private stdin config, never argv.
    config = ('header = "Authorization: Bearer ' + access + '"\n').encode("ascii")
    seconds = min(20, remaining())
    code, raw = child([
        "curl", "-q", "--config", "-", "--fail-with-body", "--silent", "--show-error",
        "--globoff", "--proto", "=https", "--max-redirs", "0", "--suppress-connect-headers",
        "--connect-timeout", "5", "--max-time", str(seconds), "--max-filesize", str(cap),
        "--include", "--header", "Accept-Encoding: " + ("gzip" if media else "identity"), *extra, url,
    ], config, cap + HEADER_CAP, seconds, http_cap=cap)
    header_bytes = 0
    while True:
        end = raw.find(b"\r\n\r\n")
        if end < 0 or header_bytes + end + 4 > HEADER_CAP:
            raise Failure("Google API response has invalid or excessive HTTP headers.")
        lines = raw[:end].split(b"\r\n")
        match = re.fullmatch(rb"HTTP/[0-9.]+ ([0-9]{3})(?: [^\r\n]*)?", lines[0])
        if not match:
            raise Failure("Google API response has an invalid HTTP status.")
        status = int(match[1])
        headers = {}
        for line in lines[1:]:
            name, separator, value = line.partition(b":")
            if not separator or not re.fullmatch(rb"[A-Za-z0-9-]+", name):
                raise Failure("Google API response has malformed HTTP headers.")
            name = name.lower()
            if name in headers and name in {b"content-range", b"content-length", b"content-encoding", b"transfer-encoding", b"location"}:
                raise Failure("Google API response has duplicate framing or range headers.")
            headers[name] = value.strip().decode("latin-1")
        header_bytes += end + 4
        raw = raw[end + 4:]
        if not 100 <= status < 200:
            break
    if len(raw) > cap:
        raise Failure("Google API response exceeded its byte limit.")
    if not 200 <= status < 300:
        # Do not expose provider error bodies, request URLs, credentials or headers.
        raise Failure("Google API rejected driver-log read (HTTP %d)." % status)
    if code == 63:
        raise Failure("Google API response exceeded its body byte limit.")
    if code != 0:
        raise Failure("Google API transfer failed (client exit %d)." % code)
    if headers.get(b"content-encoding", "identity").lower() != "identity":
        raise Failure("Encoded driver-log responses are unsupported.")
    return status, headers, raw


def decimal(value, minimum=0):
    if type(value) is not str or not re.fullmatch(r"0|[1-9][0-9]{0,18}", value):
        raise Failure("Google object metadata contains an invalid decimal string.")
    number = int(value)
    if not minimum <= number <= I64:
        raise Failure("Google object metadata exceeds the supported int64 range.")
    return number


def number_arg(value, maximum):
    if not re.fullmatch(r"[1-9][0-9]{0,3}", value) or not 1 <= int(value) <= maximum:
        raise Failure("Driver-log limit is outside the supported range.")
    return int(value)


def main():
    if len(sys.argv) != 6:
        raise Failure("Expected project, region, job, lines and bytes.")
    project, region, job, lines_arg, bytes_arg = sys.argv[1:]
    if not (re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project)
            and re.fullmatch(r"[a-z][a-z0-9-]{0,62}", region)
            and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", job)):
        raise Failure("Invalid Dataproc job selector.")
    line_limit = number_arg(lines_arg, 200)
    byte_limit = number_arg(bytes_arg, 4096)
    endpoint = os.environ.get("CLOUDSDK_API_ENDPOINT_OVERRIDES_DATAPROC", "https://dataproc.googleapis.com").rstrip("/")
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?", endpoint):
        raise Failure("Dataproc endpoint must be an HTTPS origin.")
    code, token = child(["gcloud", "auth", "print-access-token", "--quiet"], cap=4096, seconds=10)
    try:
        access = token.decode("ascii").strip()
    except UnicodeError:
        access = ""
    if code != 0 or not re.fullmatch(r"[A-Za-z0-9._~+/-]{1,4094}={0,2}", access):
        raise Failure("Could not obtain a bounded gcloud access token.")
    _, _, raw = http(endpoint + "/v1/projects/" + project + "/regions/" + region + "/jobs/" + job, access, METADATA_CAP)
    metadata = decode(raw)
    reference = metadata.get("reference")
    if type(reference) is not dict or reference.get("projectId") != project or reference.get("jobId") != job:
        raise Failure("Dataproc returned a different project or job identity.")
    state = metadata.get("status", {}).get("state") if type(metadata.get("status")) is dict else None
    if type(state) is not str or not re.fullmatch(r"[A-Z_]{1,32}", state):
        raise Failure("Dataproc returned an invalid job state.")
    uri = metadata.get("driverOutputResourceUri")
    match = re.fullmatch(r"gs://([a-z0-9][a-z0-9._-]{1,220}[a-z0-9])/([A-Za-z0-9_./-]{1,1003})", uri) if type(uri) is str else None
    if not match or any(p in ("", ".", "..") for p in match[2].split("/")) or ".." in match[1]:
        raise Failure("Job has no supported, unambiguous provider driver-log URI.")
    bucket, prefix = match.groups()
    # Do not invent a cluster UUID path grammar: Google owns this output-only URI.
    list_url = "https://storage.googleapis.com/storage/v1/b/" + quote(bucket, safe="") + "/o"
    token = ""
    seen_tokens = set()
    chunks = {}
    for page in range(5):
        query = {"prefix": prefix + ".", "maxResults": "1000",
                 "fields": "nextPageToken,items(name,generation,size,contentEncoding)"}
        if token:
            query["pageToken"] = token
        _, _, raw = http(list_url + "?" + urlencode(query), access, METADATA_CAP)
        result = decode(raw)
        items = result.get("items", [])
        if type(items) is not list or len(items) > 1000:
            raise Failure("Google object listing contains an invalid page.")
        for item in items:
            if type(item) is not dict or type(item.get("name")) is not str or not item["name"].startswith(prefix + "."):
                raise Failure("Google object listing escaped the job driver-log prefix.")
            suffix = item["name"][len(prefix) + 1:]
            if not re.fullmatch(r"(?:[0-9]{9}|[1-9][0-9]{9,19})", suffix):
                raise Failure("Google driver-log chunk has an unsupported numeric suffix.")
            index = int(suffix)
            if index in chunks:
                raise Failure("Google driver-log listing repeated a chunk.")
            size = decimal(item.get("size"))
            decimal(item.get("generation"), 1)
            if item.get("contentEncoding", "identity").lower() != "identity":
                raise Failure("Encoded driver-log objects are unsupported.")
            chunks[index] = (item["name"], item["generation"], size)
        token = result.get("nextPageToken", "")
        if type(token) is not str or len(token) > 4096 or any(not 33 <= ord(c) <= 126 for c in token):
            raise Failure("Google object listing returned an unsupported page token.")
        if not token:
            break
        if token in seen_tokens:
            raise Failure("Google object listing repeated a page token.")
        seen_tokens.add(token)
    if token:
        raise Failure("Driver-log listing exceeded its five-page budget; no log body was fetched.")
    indices = sorted(chunks)
    if any(b != a + 1 for a, b in zip(indices, indices[1:])) or any(chunks[i][2] == 0 for i in indices[:-1]):
        raise Failure("Driver-log chunks contain a gap or an intermediate empty sentinel.")
    nonempty = [i for i in indices if chunks[i][2]]
    selected = nonempty[-4:]
    pieces = []
    bytes_read = 0
    fetched = 0
    partial = False
    for index in reversed(selected):
        name, generation, size = chunks[index]
        count = min(size, byte_limit - bytes_read)
        if count <= 0:
            break
        media_url = "https://storage.googleapis.com/download/storage/v1/b/" + quote(bucket, safe="") + "/o/" + quote(name, safe="")
        media_url += "?" + urlencode({"alt": "media", "generation": generation})
        status, headers, body = http(media_url, access, count, ("--header", "Range: bytes=-" + str(count)), media=True)
        if status == 206:
            expected = "bytes %d-%d/%d" % (size - count, size - 1, size)
            if headers.get(b"content-range") != expected or len(body) != count:
                raise Failure("Google driver-log byte range did not match the pinned object.")
        elif status != 200 or size > count or len(body) != size or b"content-range" in headers:
            raise Failure("Google driver-log response ignored the bounded byte range.")
        pieces.insert(0, body)
        bytes_read += len(body)
        fetched += 1
        partial = count < size
    raw = b"".join(pieces)
    truncated = partial or fetched < len(nonempty) or (bool(indices) and indices[0] != 0)
    partial = partial or fetched < len(nonempty) or (bool(indices) and indices[0] != 0)
    # Every retained segment is byte-concatenated before line selection. Preserve
    # the final newline and never invent one between provider chunks.
    text = raw.decode("utf-8", errors="replace")
    text = "".join(c if c in "\n\t" or (ord(c) >= 32 and not 127 <= ord(c) <= 159) else " " for c in text)
    while len(text.encode("utf-8")) > min(byte_limit, EMITTED_TEXT_CAP):
        text = text[1:]
        partial = truncated = True
    rows = text.splitlines(keepends=True)
    if len(rows) > line_limit:
        text = "".join(rows[-line_limit:])
        truncated = True
        partial = False
    result = {"id": job, "state": state, "log_available": bool(nonempty), "text": text,
              "lines_returned": len(text.splitlines()), "bytes_returned": len(text.encode("utf-8")),
              "bytes_read": bytes_read, "chunks_read": fetched, "truncated": truncated, "partial_first_line": partial}
    # Bound canonical structured JSON even for backslashes, quotes, U+2028/29 or
    # redaction replacements. Native MaxResultBytes is8192, so leave headroom.
    while len(json.dumps(result, ensure_ascii=True, separators=(",", ":")).encode("ascii")) > 7000:
        text = text[1:]
        result.update(text=text, lines_returned=len(text.splitlines()), bytes_returned=len(text.encode("utf-8")),
                      truncated=True, partial_first_line=True)
    remaining()
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))


try:
    main()
except Failure as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
except (OSError, ValueError, TypeError, AttributeError, KeyError, RecursionError):
    print("Invalid or unavailable bounded driver-log response.", file=sys.stderr)
    sys.exit(1)
PY
