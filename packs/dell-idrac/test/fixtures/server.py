"""Minimal Dell iDRAC Redfish fixture served over HTTPS.

The TLS pair is minted at container start with openssl instead of being a
committed fixture: the cases only need "a certificate no client trusts" —
which a freshly generated self-signed cert is by definition — and a private
key on disk is exactly what the repository's secret hygiene exists to keep
out of git. Serving on 443 matches the pack's fixed https://<host>/redfish
URL shape.
"""

import json
import ssl
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SYSTEM = {
    "@odata.id": "/redfish/v1/Systems/System.Embedded.1",
    "Id": "System.Embedded.1",
    "Model": "PowerEdge R750",
    "SKU": "PACKTEST1",
    "BiosVersion": "1.6.5",
    "PowerState": "On",
    "Status": {"Health": "OK", "HealthRollup": "OK"},
    "ProcessorSummary": {"Count": 2, "Status": {"Health": "OK"}},
    "MemorySummary": {"TotalSystemMemoryGiB": 256, "Status": {"Health": "OK"}},
}


def redfish_error(message):
    return {"error": {"message.extendedInfo": [{"Message": message}]}}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
            return
        if not self.headers.get("Authorization", "").startswith("Basic "):
            self.reply(401, redfish_error("Login credentials required"))
            return
        if self.path == "/redfish/v1/Systems/System.Embedded.1":
            self.reply(200, SYSTEM)
            return
        self.reply(404, redfish_error("Resource not found"))

    def reply(self, status, document):
        body = json.dumps(document).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    tls_dir = tempfile.mkdtemp()
    cert, key = tls_dir + "/server.crt", tls_dir + "/server.key"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
         "-subj", "/CN=idrac", "-keyout", key, "-out", cert],
        check=True, capture_output=True,
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
