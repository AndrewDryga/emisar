"""Real loopback HTTP/TLS origins and a recording HTTP proxy."""
import http.server
import json
import pathlib
import socket
import ssl
import threading
import urllib.parse

ROOT = pathlib.Path("/tmp/packtest-net-fixture")
LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.respond()

    def do_HEAD(self):
        self.respond()

    def respond(self):
        host = self.headers.get("Host", "")
        sni = getattr(self.connection, "fixture_sni", None)
        with LOCK, (ROOT / "requests.jsonl").open("a") as output:
            output.write(json.dumps({"host": host, "sni": sni, "path": self.path,
                                     "port": self.server.server_port,
                                     "method": self.command}) + "\n")
        location = None
        path = urllib.parse.urlsplit(self.path).path
        code = 201 if host.split(":")[0].lower() == "packtest.invalid" else 421
        if self.server.server_port == 24481:
            code = 203
        elif path == "/redirect-same":
            code, location = 302, "/selected"
        elif path == "/redirect-host":
            code, location = 302, "http://other.invalid:24480/selected"
        elif path == "/redirect-port":
            code, location = 302, "http://packtest.invalid:24482/selected"
        elif path == "/redirect-tcp":
            code, location = 302, "http://tcp/"
        elif path == "/redirect-file":
            code, location = 302, "file:///tmp/not-a-response"
        elif path == "/loop":
            number = int(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("n", [0])[0])
            code, location = 302, "/loop?n=" + str(number + 1)
        elif path == "/status/404":
            code = 404
        elif path == "/status/503":
            code = 503
        self.send_response(code)
        self.send_header("X-Fixture-Host", host)
        self.send_header("X-Fixture-SNI", sni or "none")
        self.send_header("X-Fixture-Port", str(self.server.server_port))
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()


class IPv6Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(ROOT / "server.crt", ROOT / "server.key")


def record_sni(connection, name, _context):
    connection.fixture_sni = name
    with LOCK, (ROOT / "sni.jsonl").open("a") as output:
        output.write(json.dumps({"name": name, "port": connection.getsockname()[1]}) + "\n")


context.set_servername_callback(record_sni)
servers = []
for host, port, tls in [("127.0.0.1", 80, False), ("127.0.0.1", 443, True),
                        ("127.0.0.1", 24480, False), ("127.0.0.1", 24481, False),
                        ("127.0.0.1", 24482, False), ("127.0.0.1", 24443, True),
                        ("::1", 24443, True), ("::1", 24446, True)]:
    server_type = IPv6Server if ":" in host else http.server.ThreadingHTTPServer
    server = server_type((host, port), Handler)
    if tls:
        server.socket = context.wrap_socket(server.socket, server_side=True)
    servers.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
(ROOT / "ready").touch()
threading.Event().wait()
