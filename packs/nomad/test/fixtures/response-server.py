"""Transport faults for the real, digest-pinned Nomad CLI, never a CLI stub."""

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


lock = threading.Lock()
state = {"mode": "length", "size": 256, "observed": {}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def document(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/health":
            return self.document({"ok": True})
        if url.path == "/configure":
            with lock:
                state.update(mode=query["mode"][0], size=int(query.get("size", [256])[0]), observed={})
            return self.document({"ok": True})
        if url.path == "/observed":
            with lock:
                return self.document(state["observed"].copy())
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


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
