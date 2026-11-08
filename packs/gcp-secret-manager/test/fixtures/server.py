"""Disposable v1 SecretVersion metadata contract; no payload API is implemented."""
import json
import re
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ACCESS = "packtest-canary-secret-manager-access-882d"
PRIVATE = "packtest-canary-secret-manager-private-extra-29ac"
REQUESTS = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, code, value, headers=()):
        raw = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def error(self, code, status):
        self.send(code, {"error": {"code": code, "status": status,
                                 "message": PRIVATE, "details": [{"payload": PRIVATE}]}, "private": PRIVATE})

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            self.send(200, {})
            return
        if u.path == "/probe/state":
            self.send(200, {"requests": REQUESTS, "access_called": any(":access" in r["path"] for r in REQUESTS)})
            return
        query = parse_qs(u.query)
        length = int(self.headers.get("Content-Length", 0))
        REQUESTS.append({"method": "GET", "path": u.path, "query": query,
                         "body_length": length, "authorization_present": self.headers.get("Authorization") is not None,
                         "accept_encoding": self.headers.get("Accept-Encoding"), "host": self.headers.get("Host")})
        if self.headers.get("Authorization") != "Bearer " + ACCESS:
            self.error(403, "PERMISSION_DENIED")
            return
        match = re.fullmatch(r"/v1/projects/([a-z][a-z0-9-]{4,28}[a-z0-9])/secrets/([A-Za-z0-9_-]{1,255})/versions/(latest|[1-9][0-9]{0,31})", u.path)
        if not match or length or query != {"fields": ["name,state,createTime,destroyTime"]} or self.headers.get("Accept-Encoding") != "identity" or self.headers.get("Host") != "secretmanager.googleapis.com":
            self.error(400, "INVALID_ARGUMENT")
            return
        project, secret, requested = match.groups()
        if secret == "denied-secret":
            self.error(403, "PERMISSION_DENIED")
            return
        if secret == "missing-secret":
            self.error(404, "NOT_FOUND")
            return
        version = "7" if requested == "latest" else requested
        canonical = "133890521114" if secret in ("canonical-secret", "disabled-secret", "destroyed-secret") else project
        value = {"name": f"projects/{canonical}/secrets/{secret}/versions/{version}", "state": "ENABLED", "createTime": "2026-11-07T22:00:00.123456789Z"}
        if secret in ("disabled-secret", "destroyed-secret"):
            value["state"] = "DISABLED" if secret == "disabled-secret" else "DESTROYED"
        if secret == "destroyed-secret":
            value["destroyTime"] = "2026-11-07T22:10:00Z"
        if secret == "newline-name":
            value["name"] += "\n"
        if secret == "nul-name":
            value["name"] += "\x00"
        if secret == "newline-state":
            value["state"] += "\n"
        if secret == "newline-time":
            value["createTime"] = "2026-11-07T22:00:00Z\n"
        if secret == "nul-destroy-time":
            value["state"] = "DESTROYED"
            value["destroyTime"] = "2026-11-07T22:10:00Z\x00"
        if secret == "wrong-secret":
            value["name"] = f"projects/{project}/secrets/another-secret/versions/{version}"
        if secret == "wrong-project":
            value["name"] = f"projects/different-project/secrets/{secret}/versions/{version}"
        if secret == "wrong-version":
            value["name"] = f"projects/{project}/secrets/{secret}/versions/88"
        if secret == "regional-secret":
            value["name"] = value["name"].replace("/secrets/", "/locations/us-central1/secrets/")
        if secret == "extra-path-secret":
            value["name"] += "/payload"
        if secret == "invalid-state":
            value["state"] = "STATE_UNSPECIFIED"
        if secret == "invalid-time":
            value["createTime"] = "not-a-timestamp"
        if secret == "missing-time":
            value.pop("createTime")
        if secret == "time-type":
            value["createTime"] = 1794088800
        if secret == "long-time":
            value["createTime"] = "2026-11-07T22:00:00.1234567890Z"
        if secret == "wrong-destroy-time":
            value["destroyTime"] = "2026-11-07T22:10:00Z"
        if secret == "null-destroy-time":
            value["destroyTime"] = None
        if secret == "extra-fields":
            value.update(payload={"data": PRIVATE}, replicationStatus={"private": PRIVATE}, etag=PRIVATE)
        if secret == "malformed-secret":
            value = [value]
        if secret == "oversize-secret":
            value["padding"] = "x" * 65537
        if secret == "redirect-secret":
            self.send(302, value, [("Location", "https://forbidden.invalid/private")])
            return
        if secret == "chunked-secret":
            self.protocol_version = "HTTP/1.1"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(80):
                    chunk = b"x" * 1024
                    self.wfile.write(b"400\r\n" + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            return
        self.send(200, value)

    def do_POST(self):
        REQUESTS.append({"method": "POST", "path": urlparse(self.path).path})
        self.error(405, "METHOD_NOT_ALLOWED")


server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
