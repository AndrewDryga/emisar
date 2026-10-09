"""Transport faults for the real, digest-pinned Nomad CLI, never a CLI stub."""

import json
import os
import socket
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


lock = threading.Lock()
state = {"mode": "length", "size": 256, "observed": {}, "redirected": 0}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def document(self, value, status=200, headers=None):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/health":
            return self.document({"ok": True})
        if url.path == "/configure":
            with lock:
                state.update(mode=query["mode"][0], size=int(query.get("size", [256])[0]), observed={}, redirected=0)
            return self.document({"ok": True})
        if url.path == "/observed":
            with lock:
                return self.document({**state["observed"], "redirected": state["redirected"]})
        if url.path == "/redirected":
            with lock:
                state["redirected"] += 1
            return self.document({"fixture": "redirect destination"})
        api_kind = self.api_kind(url.path)
        if api_kind is not None:
            return self.api_response(url, query, api_kind)
        if url.path not in ("/v1/jobs", "/v1/allocations"):
            self.send_error(404)
            return

        with lock:
            mode, size = state["mode"], state["size"]
            observed = {
                "path": url.path,
                "query": query,
                "token": self.headers.get("X-Nomad-Token"),
                "written": 0,
            }
            state["observed"] = observed
        if mode in ("401", "403", "500"):
            self.send_error(int(mode))
            return
        prefix, suffix = b'[{"ID":"fixture","Unused":"', b'"}]'
        try:
            self.send_response(200)
            if mode in ("length", "disconnect"):
                self.send_header("Content-Length", str(size))
            elif mode == "chunked":
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if mode == "disconnect":
                self.wfile.write(b"[]")
                self.close_connection = True
                return
            if mode == "empty":
                return
            if mode == "hold":
                while True:
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.05)

            def write(chunk):
                if mode == "chunked":
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                else:
                    self.wfile.write(chunk)
                with lock:
                    observed["written"] += len(chunk)

            write(prefix)
            remaining = size - len(prefix) - len(suffix)
            block = "🙂".encode() * 8192
            while remaining >= len(block):
                write(block)
                remaining -= len(block)
            if remaining:
                write("🙂".encode() * (remaining // 4) + b"x" * (remaining % 4))
            write(suffix)
            if mode == "chunked":
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass  # A bounded/cancelled client is expected to stop the producer.

    def api_kind(self, path):
        if path == "/v1/status/leader":
            return "string"
        if path == "/v1/nodes" or path.startswith("/v1/client/fs/ls/"):
            return "array"
        if path in ("/v1/agent/self", "/v1/agent/members", "/v1/operator/autopilot/health"):
            return "object"
        if path.startswith("/v1/client/allocation/") or path.startswith("/v1/client/fs/stat/"):
            return "object"
        if path.startswith("/v1/node/") and path.endswith("/purge"):
            return "object"
        return None

    def do_PUT(self):
        url = urlsplit(self.path)
        kind = self.api_kind(url.path)
        if kind is None:
            return self.send_error(404)
        return self.api_response(url, parse_qs(url.query), kind)

    def api_response(self, url, query, kind):
        with lock:
            mode = state["mode"]
            state["observed"] = {
                "method": self.command,
                "path": url.path,
                "query": query,
                "token": self.headers.get("X-Nomad-Token"),
                "authorization": self.headers.get("Authorization"),
                "host": self.headers.get("Host"),
            }
        if mode == "api-redirect":
            return self.document({"error": "fixture redirect"}, 302, {"Location": "/redirected"})
        if mode.startswith("api-") and mode[4:].isdigit():
            return self.document({"error": "fixture API rejection"}, int(mode[4:]))
        if mode == "api-ok":
            value = {"fixture": "Nomad API"}
            if kind == "array":
                value = [value]
            elif kind == "string":
                value = "fixture:4647"
            return self.document(value)
        if mode == "api-empty-leader":
            return self.document("")
        bodies = {"api-html": b"<html>fixture non-JSON response</html>", "api-empty": b"", "api-multiple": b"{} {}"}
        body = bodies.get(mode, b"fixture unsupported response")
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
tls_context.load_cert_chain("/fixture/tls/server.pem", "/fixture/tls/server-key.pem")
tls_context.load_verify_locations("/fixture/tls/ca.pem")
tls_context.verify_mode = ssl.CERT_REQUIRED
tls_server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
tls_server.socket = tls_context.wrap_socket(tls_server.socket, server_side=True)
threading.Thread(target=tls_server.serve_forever, daemon=True).start()


class UnixHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        self.socket.bind(self.server_address)
        self.server_name = "localhost"
        self.server_port = 0


unix_server = UnixHTTPServer("/fixture-sockets/nomad.sock", Handler)
os.chmod("/fixture-sockets/nomad.sock", 0o666)
threading.Thread(target=unix_server.serve_forever, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
