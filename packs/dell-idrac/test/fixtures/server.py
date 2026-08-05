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


# Every accepted POST is recorded and served back at /packtest/posted, so a case
# can PROBE what the action did rather than only reading the action's own
# stdout. That is the difference the harness insists on for a mutating action:
# an observable state change, not a self-report.
POSTED = []


def redfish_error(message):
    return {"error": {"message.extendedInfo": [{"Message": message}]}}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
            return
        # Fixture introspection, ahead of the auth check like /health: the probe
        # asks what the BMC recorded, and it is not exercising Redfish auth.
        if self.path == "/packtest/posted":
            self.reply(200, {"posted": POSTED})
            return
        if not self.headers.get("Authorization", "").startswith("Basic "):
            self.reply(401, redfish_error("Login credentials required"))
            return
        if self.path == "/redfish/v1/Systems/System.Embedded.1":
            self.reply(200, SYSTEM)
            return
        self.reply(404, redfish_error("Resource not found"))

    # The three risky actions are all POSTs, and the fixture had no do_POST at
    # all — so nothing had ever exercised the URL, the method, the auth header,
    # or the JSON body any of them sends. A mock cannot prove a real BMC obeys,
    # but it proves the pack asks correctly, which is where a Redfish call
    # actually goes wrong.
    POST_ACTIONS = {
        "/redfish/v1/Managers/iDRAC.Embedded.1/LogServices/Sel/Actions/LogService.ClearLog": None,
        "/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellJobService/Actions/DellJobService.DeleteJobQueue": "JobID",
        "/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset": "ResetType",
    }

    def do_POST(self):
        if not self.headers.get("Authorization", "").startswith("Basic "):
            self.reply(401, redfish_error("Login credentials required"))
            return
        if self.path not in self.POST_ACTIONS:
            self.reply(404, redfish_error("Resource not found"))
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw or b"{}")
        except ValueError:
            self.reply(400, redfish_error("Malformed JSON body"))
            return
        if not isinstance(payload, dict):
            self.reply(400, redfish_error("Body must be a JSON object"))
            return

        # Echo the field back so a case can assert the action sent the argument
        # the operator chose, not merely that something was POSTed.
        required = self.POST_ACTIONS[self.path]
        if required is not None:
            if required not in payload:
                self.reply(400, redfish_error("Missing %s" % required))
                return
            POSTED.append({"path": self.path, required: payload[required]})
            self.reply(200, {"Accepted": self.path, required: payload[required]})
            return
        POSTED.append({"path": self.path})
        self.reply(200, {"Accepted": self.path})

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
